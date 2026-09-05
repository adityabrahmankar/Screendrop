//
//  MetalStudioScreenRenderer.swift
//  Screendrop
//
//  GPU backend for the screen-video portion of Studio exports. The rest of
//  the Studio compositor intentionally stays on Core Graphics for now: this
//  renderer owns only the static backdrop, the zoomed screen frame, and its
//  temporal supersampling.
//

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalKit

nonisolated enum MetalStudioScreenAccumulation: String, Sendable {
    case fp16
    case fp32

    static var configured: Self {
        guard let value = ProcessInfo.processInfo.environment[
            "SCREENDROP_STUDIO_METAL_ACCUMULATION"
        ]?.lowercased() else {
            return .fp16
        }
        switch value {
        case "fp32", "float32", "32": return .fp32
        default: return .fp16
        }
    }

    var pixelFormat: MTLPixelFormat {
        switch self {
        case .fp16: return .rgba16Float
        case .fp32: return .rgba32Float
        }
    }

    var textureFormatName: String {
        switch self {
        case .fp16: return "rgba16Float"
        case .fp32: return "rgba32Float"
        }
    }
}

/// Renders the screen layer into an export pixel buffer while preserving the
/// exporter's top-left layout coordinates. The CVMetalTextureCache lets each
/// decoded CVPixelBuffer be used directly by Metal without a CPU image copy.
nonisolated final class MetalStudioScreenRenderer: @unchecked Sendable {
    enum RendererError: LocalizedError {
        case noDevice
        case noCommandQueue
        case noLibrary
        case noFunctions
        case pipelineCreationFailed(Error?)
        case copyPipelineCreationFailed(Error?)
        case samplerCreationFailed
        case copySamplerCreationFailed
        case quadBufferCreationFailed
        case accumulationTextureCreationFailed
        case backdropTextureCreationFailed(Error?)
        case sourceTextureCreationFailed(OSStatus)
        case destinationTextureCreationFailed(OSStatus)
        case commandBufferCreationFailed
        case encoderCreationFailed
        case copyEncoderCreationFailed
        case commandFailed(Error?)
        case invalidDestinationSize
        case invalidSampleCount

        var errorDescription: String? {
            switch self {
            case .noDevice:
                "Metal is unavailable on this Mac."
            case .noCommandQueue:
                "Metal could not create a command queue."
            case .noLibrary:
                "Metal could not load the Studio shader library."
            case .noFunctions:
                "Metal could not find the Studio screen shaders."
            case .pipelineCreationFailed(let error):
                error?.localizedDescription ?? "Metal could not create the Studio accumulation pipeline."
            case .copyPipelineCreationFailed(let error):
                error?.localizedDescription ?? "Metal could not create the Studio output pipeline."
            case .samplerCreationFailed:
                "Metal could not create the Studio texture sampler."
            case .copySamplerCreationFailed:
                "Metal could not create the Studio accumulation sampler."
            case .quadBufferCreationFailed:
                "Metal could not allocate the Studio quad buffer."
            case .accumulationTextureCreationFailed:
                "Metal could not allocate the Studio accumulation texture."
            case .backdropTextureCreationFailed(let error):
                error?.localizedDescription ?? "Metal could not create the Studio backdrop texture."
            case .sourceTextureCreationFailed(let status):
                "Metal could not wrap the decoded screen frame (CVReturn \(status))."
            case .destinationTextureCreationFailed(let status):
                "Metal could not wrap the export pixel buffer (CVReturn \(status))."
            case .commandBufferCreationFailed:
                "Metal could not create a Studio command buffer."
            case .encoderCreationFailed:
                "Metal could not create a Studio render encoder."
            case .copyEncoderCreationFailed:
                "Metal could not create the Studio output encoder."
            case .commandFailed(let error):
                error?.localizedDescription ?? "The Metal Studio render command failed."
            case .invalidDestinationSize:
                "The Metal Studio destination pixel buffer has the wrong size."
            case .invalidSampleCount:
                "The Metal Studio renderer received an invalid blur sample count."
            }
        }
    }

    private struct QuadVertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }

    /// Keep this layout byte-for-byte identical to StudioRenderUniforms in
    /// MetalStudioScreenRenderer.metal. Rects use a top-left origin.
    private struct RenderUniforms {
        var canvasSize: SIMD2<Float>
        var drawRect: SIMD4<Float>
        var cardRect: SIMD4<Float>
        var sourceSize: SIMD2<Float>
        var cardCornerRadius: Float
        var sampleAlpha: Float
        var filterKind: UInt32
        var clipEnabled: UInt32
        var resamplerEnabled: UInt32
    }

    let filter: MetalStudioScreenFilter
    let accumulation: MetalStudioScreenAccumulation

    private let canvasSize: CGSize
    private let cardRect: CGRect
    private let cardCornerRadius: CGFloat
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let accumulationPipelineState: any MTLRenderPipelineState
    private let copyPipelineState: any MTLRenderPipelineState
    private let screenSamplerState: any MTLSamplerState
    private let copySamplerState: any MTLSamplerState
    private let quadBuffer: any MTLBuffer
    private let accumulationTexture: any MTLTexture
    private let backdropTexture: (any MTLTexture)?

    init(
        canvasSize: CGSize,
        cardRect: CGRect,
        cardCornerRadius: CGFloat,
        backdrop: CGImage?,
        filter: MetalStudioScreenFilter = .configured,
        accumulation: MetalStudioScreenAccumulation = .configured
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        guard let library = device.makeDefaultLibrary() else {
            throw RendererError.noLibrary
        }
        guard let vertexFunction = library.makeFunction(name: "studioScreenVertex"),
              let fragmentFunction = library.makeFunction(name: "studioScreenFragment"),
              let copyFragmentFunction = library.makeFunction(name: "studioScreenCopyFragment") else {
            throw RendererError.noFunctions
        }

        let accumulationDescriptor = MTLRenderPipelineDescriptor()
        accumulationDescriptor.label = "Screendrop Studio \(accumulation.rawValue.uppercased()) screen accumulation"
        accumulationDescriptor.vertexFunction = vertexFunction
        accumulationDescriptor.fragmentFunction = fragmentFunction
        accumulationDescriptor.colorAttachments[0].pixelFormat = accumulation.pixelFormat
        let accumulationAttachment = accumulationDescriptor.colorAttachments[0]!
        accumulationAttachment.isBlendingEnabled = true
        accumulationAttachment.rgbBlendOperation = .add
        accumulationAttachment.alphaBlendOperation = .add
        accumulationAttachment.sourceRGBBlendFactor = .sourceAlpha
        accumulationAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        accumulationAttachment.sourceAlphaBlendFactor = .sourceAlpha
        accumulationAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let accumulationPipelineState: any MTLRenderPipelineState
        do {
            accumulationPipelineState = try device.makeRenderPipelineState(
                descriptor: accumulationDescriptor
            )
        } catch {
            throw RendererError.pipelineCreationFailed(error)
        }

        let copyDescriptor = MTLRenderPipelineDescriptor()
        copyDescriptor.label = "Screendrop Studio 8-bit output conversion"
        copyDescriptor.vertexFunction = vertexFunction
        copyDescriptor.fragmentFunction = copyFragmentFunction
        copyDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        copyDescriptor.colorAttachments[0].isBlendingEnabled = false

        let copyPipelineState: any MTLRenderPipelineState
        do {
            copyPipelineState = try device.makeRenderPipelineState(descriptor: copyDescriptor)
        } catch {
            throw RendererError.copyPipelineCreationFailed(error)
        }

        let screenSamplerDescriptor = MTLSamplerDescriptor()
        screenSamplerDescriptor.label = "Screendrop Studio screen sampler"
        screenSamplerDescriptor.minFilter = .linear
        screenSamplerDescriptor.magFilter = .linear
        screenSamplerDescriptor.mipFilter = .notMipmapped
        screenSamplerDescriptor.sAddressMode = .clampToEdge
        screenSamplerDescriptor.tAddressMode = .clampToEdge
        guard let screenSamplerState = device.makeSamplerState(descriptor: screenSamplerDescriptor) else {
            throw RendererError.samplerCreationFailed
        }

        let copySamplerDescriptor = MTLSamplerDescriptor()
        copySamplerDescriptor.label = "Screendrop Studio accumulation sampler"
        copySamplerDescriptor.minFilter = .nearest
        copySamplerDescriptor.magFilter = .nearest
        copySamplerDescriptor.mipFilter = .notMipmapped
        copySamplerDescriptor.sAddressMode = .clampToEdge
        copySamplerDescriptor.tAddressMode = .clampToEdge
        guard let copySamplerState = device.makeSamplerState(descriptor: copySamplerDescriptor) else {
            throw RendererError.copySamplerCreationFailed
        }

        let vertices = [
            QuadVertex(position: SIMD2<Float>(0, 0), texCoord: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(1, 0), texCoord: SIMD2<Float>(1, 0)),
            QuadVertex(position: SIMD2<Float>(0, 1), texCoord: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(1, 1), texCoord: SIMD2<Float>(1, 1)),
        ]
        guard let quadBuffer = vertices.withUnsafeBytes({ bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            )
        }) else {
            throw RendererError.quadBufferCreationFailed
        }
        quadBuffer.label = "Screendrop Studio unit quad"

        var textureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
        guard cacheStatus == kCVReturnSuccess, let textureCache else {
            throw RendererError.sourceTextureCreationFailed(cacheStatus)
        }

        var backdropTexture: (any MTLTexture)?
        if let backdrop {
            let loader = MTKTextureLoader(device: device)
            do {
                backdropTexture = try loader.newTexture(
                    cgImage: backdrop,
                    options: [
                        .SRGB: false,
                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                    ]
                )
                backdropTexture?.label = "Screendrop Studio static backdrop"
            } catch {
                throw RendererError.backdropTextureCreationFailed(error)
            }
        }

        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw RendererError.invalidDestinationSize
        }
        let accumulationTextureDescriptor = MTLTextureDescriptor()
        accumulationTextureDescriptor.textureType = .type2D
        accumulationTextureDescriptor.pixelFormat = accumulation.pixelFormat
        accumulationTextureDescriptor.width = Int(canvasSize.width.rounded())
        accumulationTextureDescriptor.height = Int(canvasSize.height.rounded())
        accumulationTextureDescriptor.mipmapLevelCount = 1
        accumulationTextureDescriptor.sampleCount = 1
        accumulationTextureDescriptor.usage = [.renderTarget, .shaderRead]
        accumulationTextureDescriptor.storageMode = .private
        guard let accumulationTexture = device.makeTexture(descriptor: accumulationTextureDescriptor) else {
            throw RendererError.accumulationTextureCreationFailed
        }
        accumulationTexture.label = "Screendrop Studio \(accumulation.rawValue.uppercased()) accumulation"

        self.filter = filter
        self.accumulation = accumulation
        self.canvasSize = canvasSize
        self.cardRect = cardRect
        self.cardCornerRadius = cardCornerRadius
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.accumulationPipelineState = accumulationPipelineState
        self.copyPipelineState = copyPipelineState
        self.screenSamplerState = screenSamplerState
        self.copySamplerState = copySamplerState
        self.quadBuffer = quadBuffer
        self.accumulationTexture = accumulationTexture
        self.backdropTexture = backdropTexture
    }

    /// Draws the static backdrop once and then averages the supplied screen
    /// rectangles in order. The caller supplies one through twenty-four
    /// rects, so the alpha sequence and sample count stay exactly the same as
    /// the Core Graphics reference backend. Samples accumulate in the
    /// configured floating-point texture and are converted to the writer's
    /// 8-bit BGRA buffer only once at the end.
    func render(
        screenFrame: CVPixelBuffer,
        destination: CVPixelBuffer,
        sampleRects: [CGRect]
    ) throws {
        guard (1...24).contains(sampleRects.count) else {
            throw RendererError.invalidSampleCount
        }
        guard CVPixelBufferGetWidth(destination) == Int(canvasSize.width),
              CVPixelBufferGetHeight(destination) == Int(canvasSize.height) else {
            throw RendererError.invalidDestinationSize
        }

        let sourceTexture = try texture(
            from: screenFrame,
            pixelFormat: .bgra8Unorm,
            failure: RendererError.sourceTextureCreationFailed
        )
        let destinationTexture = try texture(
            from: destination,
            pixelFormat: .bgra8Unorm,
            failure: RendererError.destinationTextureCreationFailed
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RendererError.commandBufferCreationFailed
        }
        commandBuffer.label = "Screendrop Studio frame"

        let accumulationPass = MTLRenderPassDescriptor()
        let accumulationAttachment = accumulationPass.colorAttachments[0]!
        accumulationAttachment.texture = accumulationTexture
        accumulationAttachment.loadAction = .clear
        accumulationAttachment.storeAction = .store
        accumulationAttachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let accumulationEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: accumulationPass
        ) else {
            throw RendererError.encoderCreationFailed
        }
        accumulationEncoder.label = "Screendrop Studio \(accumulation.rawValue.uppercased()) screen pass"
        accumulationEncoder.setRenderPipelineState(accumulationPipelineState)
        accumulationEncoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        accumulationEncoder.setFragmentSamplerState(screenSamplerState, index: 0)

        if let backdropTexture {
            var uniforms = makeUniforms(
                drawRect: CGRect(origin: .zero, size: canvasSize),
                sourceSize: CGSize(
                    width: backdropTexture.width,
                    height: backdropTexture.height
                ),
                sampleAlpha: 1,
                filterKind: .area,
                clipEnabled: false,
                resamplerEnabled: false
            )
            set(uniforms: &uniforms, on: accumulationEncoder)
            accumulationEncoder.setFragmentTexture(backdropTexture, index: 0)
            accumulationEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        accumulationEncoder.setFragmentTexture(sourceTexture, index: 0)
        let sourceSize = CGSize(width: sourceTexture.width, height: sourceTexture.height)
        for (sample, drawRect) in sampleRects.enumerated() {
            var uniforms = makeUniforms(
                drawRect: drawRect,
                sourceSize: sourceSize,
                sampleAlpha: 1 / Float(sample + 1),
                filterKind: filter,
                clipEnabled: true,
                resamplerEnabled: true
            )
            set(uniforms: &uniforms, on: accumulationEncoder)
            accumulationEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        accumulationEncoder.endEncoding()

        let copyPass = MTLRenderPassDescriptor()
        let copyAttachment = copyPass.colorAttachments[0]!
        copyAttachment.texture = destinationTexture
        copyAttachment.loadAction = .dontCare
        copyAttachment.storeAction = .store
        guard let copyEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: copyPass) else {
            throw RendererError.copyEncoderCreationFailed
        }
        copyEncoder.label = "Screendrop Studio 8-bit output pass"
        copyEncoder.setRenderPipelineState(copyPipelineState)
        copyEncoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        var copyUniforms = makeUniforms(
            drawRect: CGRect(origin: .zero, size: canvasSize),
            sourceSize: canvasSize,
            sampleAlpha: 1,
            filterKind: .area,
            clipEnabled: false,
            resamplerEnabled: false
        )
        set(uniforms: &copyUniforms, on: copyEncoder)
        copyEncoder.setFragmentSamplerState(copySamplerState, index: 0)
        copyEncoder.setFragmentTexture(accumulationTexture, index: 0)
        copyEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        copyEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw RendererError.commandFailed(commandBuffer.error)
        }
    }

    private func makeUniforms(
        drawRect: CGRect,
        sourceSize: CGSize,
        sampleAlpha: Float,
        filterKind: MetalStudioScreenFilter,
        clipEnabled: Bool,
        resamplerEnabled: Bool
    ) -> RenderUniforms {
        RenderUniforms(
            canvasSize: SIMD2<Float>(Float(canvasSize.width), Float(canvasSize.height)),
            drawRect: SIMD4<Float>(
                Float(drawRect.minX),
                Float(drawRect.minY),
                Float(drawRect.width),
                Float(drawRect.height)
            ),
            cardRect: SIMD4<Float>(
                Float(cardRect.minX),
                Float(cardRect.minY),
                Float(cardRect.width),
                Float(cardRect.height)
            ),
            sourceSize: SIMD2<Float>(Float(sourceSize.width), Float(sourceSize.height)),
            cardCornerRadius: Float(cardCornerRadius),
            sampleAlpha: sampleAlpha,
            filterKind: filterKind.shaderValue,
            clipEnabled: clipEnabled ? 1 : 0,
            resamplerEnabled: resamplerEnabled ? 1 : 0
        )
    }

    private func set(
        uniforms: inout RenderUniforms,
        on encoder: any MTLRenderCommandEncoder
    ) {
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<RenderUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<RenderUniforms>.stride,
            index: 1
        )
    }

    private func texture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        failure: (OSStatus) -> RendererError
    ) throws -> any MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw failure(status)
        }
        return texture
    }
}
