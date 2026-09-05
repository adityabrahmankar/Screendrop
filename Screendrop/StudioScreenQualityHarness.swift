import CoreGraphics
import CoreVideo
import Foundation

nonisolated enum MetalStudioScreenFilter: String, CaseIterable, Sendable {
    /// The pre-milestone fixed four-by-four kernel, retained as the raw
    /// comparison baseline. It is not the production candidate after this
    /// milestone.
    case catmullRom = "catmull-rom"
    case lanczos3
    case lanczos5
    case mitchell
    case area
    case catmullRomScaleAware = "catmull-rom-scale-aware"

    static var configured: Self {
        guard let value = ProcessInfo.processInfo.environment[
            "SCREENDROP_STUDIO_METAL_FILTER"
        ]?.lowercased() else {
            // Mitchell is the highest-fidelity candidate from the raw
            // pre-encoder comparison at the production 1080p scale.
            return .mitchell
        }

        switch value {
        case "catmull", "catmull-rom", "catmullrom":
            return .catmullRom
        case "lanczos3", "lanczos-3", "l3":
            return .lanczos3
        case "lanczos5", "lanczos-5", "l5":
            return .lanczos5
        case "mitchell", "mitchell-netravali":
            return .mitchell
        case "area", "box":
            return .area
        case "catmull-rom-scale-aware", "catmullrom-scale-aware", "scale-aware-catmull-rom":
            return .catmullRomScaleAware
        default:
            return .mitchell
        }
    }

    var shaderValue: UInt32 {
        switch self {
        case .catmullRom: return 0
        case .lanczos3: return 1
        case .lanczos5: return 2
        case .mitchell: return 3
        case .area: return 4
        case .catmullRomScaleAware: return 5
        }
    }
}

/// The Core Graphics screen-layer reference. Keeping this separate from the
/// overlay compositor lets the debug harness capture precisely the pixels
/// that existed before pointer, camera, keystroke, and subtitle overlays.
nonisolated final class StudioCoreGraphicsScreenRenderer: @unchecked Sendable {
    private let canvasSize: CGSize
    private let cardRect: CGRect
    private let cardCornerRadius: CGFloat
    private let colorSpace: CGColorSpace
    private let backdrop: CGImage?

    init(
        canvasSize: CGSize,
        cardRect: CGRect,
        cardCornerRadius: CGFloat,
        colorSpace: CGColorSpace,
        backdrop: CGImage?
    ) {
        self.canvasSize = canvasSize
        self.cardRect = cardRect
        self.cardCornerRadius = cardCornerRadius
        self.colorSpace = colorSpace
        self.backdrop = backdrop
    }

    func render(
        screenFrame: CVPixelBuffer,
        destination: CVPixelBuffer,
        sampleRects: [CGRect]
    ) -> Bool {
        withDestinationContext(destination) { context in
            drawBackdrop(in: context)
            guard let screenImage = Self.makeImage(from: screenFrame, colorSpace: colorSpace) else {
                return
            }

            context.saveGState()
            context.addPath(roundedPath())
            context.clip()
            for (sample, drawRect) in sampleRects.enumerated() {
                // Drawing sample i at alpha 1/(i+1) keeps the buffer equal to
                // the running average of all samples so far.
                context.setAlpha(1 / CGFloat(sample + 1))
                context.draw(screenImage, in: flipped(drawRect))
            }
            context.restoreGState()
        }
    }

    private func withDestinationContext(
        _ destination: CVPixelBuffer,
        body: (CGContext) -> Void
    ) -> Bool {
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let base = CVPixelBufferGetBaseAddress(destination),
              let context = CGContext(
                  data: base,
                  width: CVPixelBufferGetWidth(destination),
                  height: CVPixelBufferGetHeight(destination),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return false
        }
        context.interpolationQuality = .high
        body(context)
        return true
    }

    private func drawBackdrop(in context: CGContext) {
        if let backdrop {
            context.draw(backdrop, in: CGRect(origin: .zero, size: canvasSize))
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvasSize))
        }
    }

    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func roundedPath() -> CGPath {
        let flippedRect = flipped(cardRect)
        let boundedRadius = min(
            cardCornerRadius,
            min(flippedRect.width, flippedRect.height) / 2
        )
        guard boundedRadius > 0.5 else {
            return CGPath(rect: flippedRect, transform: nil)
        }
        return CGPath(
            roundedRect: flippedRect,
            cornerWidth: boundedRadius,
            cornerHeight: boundedRadius,
            transform: nil
        )
    }

    private static func makeImage(
        from pixelBuffer: CVPixelBuffer,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: base,
                  width: CVPixelBufferGetWidth(pixelBuffer),
                  height: CVPixelBufferGetHeight(pixelBuffer),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        return context.makeImage()
    }
}

#if DEBUG
/// Captures raw, tightly packed BGRA screen layers before AVAssetWriter. It
/// renders both backends from the same decoded frame and sample rectangles;
/// no overlays or video encoding are involved in these files.
nonisolated final class StudioScreenQualityHarness: @unchecked Sendable {
    private struct FrameRecord: Codable {
        let frameIndex: Int
        let editorTime: Double
        let sourceTime: Double
        let sampleCount: Int
        let coreGraphicsFile: String?
        let metalFile: String?
        let metalFilter: String?
        let sourceAttachments: [String: String]
        let destinationAttachments: [String: String]
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixelFormat: String
        let coordinateSystem: String
        let cardRect: [String: Double]
        let sourceTextureFormat: String
        let destinationTextureFormat: String
        let accumulationTextureFormat: String
        let bitmapInfo: String
        let colorSpace: String
        let transferFunction: String
        let captureIntervalFrames: Int
        let capturesMotionTransitions: Bool
        var frames: [FrameRecord]
    }

    private enum HarnessError: LocalizedError {
        case invalidDirectory
        case pixelBufferCreation(OSStatus)
        case missingBaseAddress
        case rawWriteFailed(URL, Error)

        var errorDescription: String? {
            switch self {
            case .invalidDirectory:
                return "The Studio screen-quality harness directory is invalid."
            case .pixelBufferCreation(let status):
                return "The Studio screen-quality harness could not allocate a BGRA buffer (CVReturn \(status))."
            case .missingBaseAddress:
                return "The Studio screen-quality harness pixel buffer has no base address."
            case .rawWriteFailed(let url, let error):
                return "The Studio screen-quality harness could not write \(url.path): \(error.localizedDescription)"
            }
        }
    }

    private let directory: URL
    private let frameDirectory: URL
    private let width: Int
    private let height: Int
    private let tightBytesPerRow: Int
    private let captureInterval: Int
    private let explicitFrames: Set<Int>
    private let capturesMotionTransitions: Bool
    private var scheduledFrames = Set<Int>()
    private var previousSampleCount = 1
    private var capturedMotionPeak = false
    private var manifest: Manifest

    static func configured(canvasSize: CGSize, cardRect: CGRect) -> Self? {
        guard let rawPath = ProcessInfo.processInfo.environment[
            "SCREENDROP_STUDIO_SCREEN_HARNESS_DIR"
        ], !rawPath.isEmpty else {
            return nil
        }

        do {
            return try Self(
                directory: URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath),
                canvasSize: canvasSize,
                cardRect: cardRect
            )
        } catch {
            fputs("[Screendrop Screen Quality] Harness disabled: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private init(directory: URL, canvasSize: CGSize, cardRect: CGRect) throws {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw HarnessError.invalidDirectory
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let frameDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(
            at: frameDirectory,
            withIntermediateDirectories: true
        )

        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        let interval = Self.environmentInt(
            "SCREENDROP_STUDIO_SCREEN_HARNESS_INTERVAL_FRAMES",
            default: 600
        )
        let explicitFrames = Self.environmentFrameSet()
        let capturesMotionTransitions = Self.environmentBool(
            "SCREENDROP_STUDIO_SCREEN_HARNESS_MOTION_TRANSITIONS",
            default: true
        )

        self.directory = directory
        self.frameDirectory = frameDirectory
        self.width = width
        self.height = height
        self.tightBytesPerRow = width * 4
        self.captureInterval = max(0, interval)
        self.explicitFrames = explicitFrames
        self.capturesMotionTransitions = capturesMotionTransitions
        self.manifest = Manifest(
            schemaVersion: 1,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            pixelFormat: "32BGRA / tightly packed",
            coordinateSystem: "top-left canvas and texture coordinates",
            cardRect: [
                "x": cardRect.minX,
                "y": cardRect.minY,
                "width": cardRect.width,
                "height": cardRect.height
            ],
            sourceTextureFormat: "bgra8Unorm",
            destinationTextureFormat: "bgra8Unorm",
            accumulationTextureFormat: MetalStudioScreenAccumulation.configured.textureFormatName,
            bitmapInfo: "premultipliedFirst | byteOrder32Little",
            colorSpace: "sRGB CGColorSpace for Core Graphics; untagged BGRA values for Metal",
            transferFunction: "source/destination CVPixelBuffer attachments recorded per frame; no implicit transfer conversion",
            captureIntervalFrames: max(0, interval),
            capturesMotionTransitions: capturesMotionTransitions,
            frames: []
        )
        try writeManifest()
    }

    func shouldCapture(frameIndex: Int, sampleCount: Int) -> Bool {
        let isMotion = sampleCount > 1
        let entersMotion = isMotion && previousSampleCount <= 1
        let leavesMotion = !isMotion && previousSampleCount > 1
        let reachesPeak = sampleCount >= 24 && !capturedMotionPeak
        let periodic = captureInterval > 0 && frameIndex % captureInterval == 0
        let explicitlyRequested = explicitFrames.contains(frameIndex)

        previousSampleCount = sampleCount
        if reachesPeak {
            capturedMotionPeak = true
        }

        guard !scheduledFrames.contains(frameIndex) else { return false }
        guard periodic || explicitlyRequested ||
                (capturesMotionTransitions && (entersMotion || leavesMotion)) ||
                reachesPeak else {
            return false
        }
        scheduledFrames.insert(frameIndex)
        return true
    }

    func capture(
        frameIndex: Int,
        editorTime: TimeInterval,
        sourceTime: TimeInterval,
        sampleCount: Int,
        screenFrame: CVPixelBuffer,
        destination: CVPixelBuffer,
        sampleRects: [CGRect],
        coreGraphicsRenderer: StudioCoreGraphicsScreenRenderer,
        metalRenderer: MetalStudioScreenRenderer?
    ) throws {
        let sourceAttachments = Self.attachments(for: screenFrame)
        let destinationAttachments = Self.attachments(for: destination)
        let coreGraphicsBuffer = try makePixelBuffer()
        guard coreGraphicsRenderer.render(
            screenFrame: screenFrame,
            destination: coreGraphicsBuffer,
            sampleRects: sampleRects
        ) else {
            throw HarnessError.missingBaseAddress
        }
        let coreGraphicsData = try rawData(from: coreGraphicsBuffer)
        let coreGraphicsName = "frame-\(String(format: "%06d", frameIndex))-coregraphics.bgra"
        let coreGraphicsURL = frameDirectory.appendingPathComponent(coreGraphicsName)
        try write(coreGraphicsData, to: coreGraphicsURL)

        var metalName: String?
        if let metalRenderer {
            let metalBuffer = try makePixelBuffer()
            try metalRenderer.render(
                screenFrame: screenFrame,
                destination: metalBuffer,
                sampleRects: sampleRects
            )
            let metalData = try rawData(from: metalBuffer)
            let filter = metalRenderer.filter.rawValue
            let name = "frame-\(String(format: "%06d", frameIndex))-metal-\(filter).bgra"
            let url = frameDirectory.appendingPathComponent(name)
            try write(metalData, to: url)
            metalName = name
        }

        manifest.frames.append(FrameRecord(
            frameIndex: frameIndex,
            editorTime: editorTime,
            sourceTime: sourceTime,
            sampleCount: sampleCount,
            coreGraphicsFile: coreGraphicsName,
            metalFile: metalName,
            metalFilter: metalRenderer?.filter.rawValue,
            sourceAttachments: sourceAttachments,
            destinationAttachments: destinationAttachments
        ))
        try writeManifest()
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw HarnessError.pixelBufferCreation(status)
        }
        return pixelBuffer
    }

    private func rawData(from pixelBuffer: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw HarnessError.missingBaseAddress
        }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var data = Data(count: tightBytesPerRow * height)
        data.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * tightBytesPerRow),
                    baseAddress.advanced(by: row * sourceBytesPerRow),
                    tightBytesPerRow
                )
            }
        }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw HarnessError.rawWriteFailed(url, error)
        }
    }

    private func writeManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private static func environmentBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[key]?.lowercased() else {
            return defaultValue
        }
        switch value {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return defaultValue
        }
    }

    private static func environmentInt(_ key: String, default defaultValue: Int) -> Int {
        guard let value = ProcessInfo.processInfo.environment[key],
              let parsed = Int(value) else {
            return defaultValue
        }
        return parsed
    }

    private static func environmentFrameSet() -> Set<Int> {
        guard let value = ProcessInfo.processInfo.environment[
            "SCREENDROP_STUDIO_SCREEN_HARNESS_FRAMES"
        ] else {
            return []
        }
        return Set(value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    private static func attachments(for pixelBuffer: CVPixelBuffer) -> [String: String] {
        guard let raw = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [AnyHashable: Any] else {
            return [:]
        }
        return raw.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
    }
}
#endif
