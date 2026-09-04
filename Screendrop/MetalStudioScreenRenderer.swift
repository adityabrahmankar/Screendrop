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
        case samplerCreationFailed
        case quadBufferCreationFailed
        case backdropTextureCreationFailed(Error?)
        case sourceTextureCreationFailed(OSStatus)
        case destinationTextureCreationFailed(OSStatus)
        case commandBufferCreationFailed
        case encoderCreationFailed
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
                error?.localizedDescription ?? "Metal could not create the Studio render pipeline."
            case .samplerCreationFailed:
                "Metal could not create the Studio texture sampler."
            case .quadBufferCreationFailed:
                "Metal could not allocate the Studio quad buffer."
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
        var cardCornerRadius: Float
        var sampleAlpha: Float
        var clipEnabled: UInt32
        var useBicubic: UInt32
    }

    private let canvasSize: CGSize
    private let cardRect: CGRect
    private let cardCornerRadius: CGFloat
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipelineState: any MTLRenderPipelineState
    private let samplerState: any MTLSamplerState
    private let quadBuffer: any MTLBuffer
    private let backdropTexture: (any MTLTexture)?

    init(
        canvasSize: CGSize,
        cardRect: CGRect,
        cardCornerRadius: CGFloat,
        backdrop: CGImage?
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
              let fragmentFunction = library.makeFunction(name: "studioScreenFragment") else {
            throw RendererError.noFunctions
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Screendrop Studio screen compositor"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .sourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let pipelineState: any MTLRenderPipelineState
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            throw RendererError.pipelineCreationFailed(error)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "Screendrop Studio screen sampler"
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.samplerCreationFailed
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

        self.canvasSize = canvasSize
        self.cardRect = cardRect
        self.cardCornerRadius = cardCornerRadius
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.pipelineState = pipelineState
        self.samplerState = samplerState
        self.quadBuffer = quadBuffer
        self.backdropTexture = backdropTexture
    }

    /// Draws the static backdrop once and then averages the supplied screen
    /// rectangles in order. The caller supplies one through twenty-four
    /// rects, so the alpha sequence and sample count stay exactly the same as
    /// the Core Graphics reference backend.
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

        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = destinationTexture
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.encoderCreationFailed
        }
        encoder.label = "Screendrop Studio screen pass"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        if let backdropTexture {
            var uniforms = RenderUniforms(
                canvasSize: SIMD2<Float>(Float(canvasSize.width), Float(canvasSize.height)),
                drawRect: SIMD4<Float>(
                    0,
                    0,
                    Float(canvasSize.width),
                    Float(canvasSize.height)
                ),
                cardRect: SIMD4<Float>(
                    Float(cardRect.minX),
                    Float(cardRect.minY),
                    Float(cardRect.width),
                    Float(cardRect.height)
                ),
                cardCornerRadius: Float(cardCornerRadius),
                sampleAlpha: 1,
                clipEnabled: 0,
                useBicubic: 0
            )
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
            encoder.setFragmentTexture(backdropTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.setFragmentTexture(sourceTexture, index: 0)
        for (sample, drawRect) in sampleRects.enumerated() {
            var uniforms = RenderUniforms(
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
                cardCornerRadius: Float(cardCornerRadius),
                sampleAlpha: 1 / Float(sample + 1),
                clipEnabled: 1,
                useBicubic: 1
            )
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
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw RendererError.commandFailed(commandBuffer.error)
        }
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
