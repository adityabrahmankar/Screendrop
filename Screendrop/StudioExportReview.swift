// Opt-in native export regression fixtures. No production code or user media.
#if DEBUG
import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import CryptoKit
import Foundation
import Metal

/// Streams hashes of every active BGRA byte, excluding uninitialized row padding.
/// Hashing runs only when explicitly requested, after GPU completion and overlays.
nonisolated final class StudioExportFrameProbe {
    private let handle: FileHandle
    static func make() throws -> StudioExportFrameProbe? {
        guard let path = ProcessInfo.processInfo.environment["SCREENDROP_STUDIO_EXPORT_DIGEST"], !path.isEmpty else { return nil }
        return try StudioExportFrameProbe(url: URL(fileURLWithPath: path))
    }
    private init(url: URL) throws {
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close() }
    func record(_ buffer: CVPixelBuffer, index: Int, time: CMTime) throws {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw NSError(domain: "ExportReview", code: 1)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw NSError(domain: "ExportReview", code: 2) }
        var hash = SHA256()
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            hash.update(data: Data(bytesNoCopy: base.advanced(by: row * stride),
                                   count: CVPixelBufferGetWidth(buffer) * 4, deallocator: .none))
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try handle.write(contentsOf: Data("\(index),\(time.value),\(time.timescale),\(digest)\n".utf8))
    }
}

/// Runs in a separate app process for each case: environment switches cannot
/// race a concurrent export. Fixture generation never requests capture access.
@MainActor enum StudioExportReview {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCREENDROP_EXPORT_REVIEW_ROOT"] else { throw Failure.assertion("missing fixture root") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mode = env["SCREENDROP_EXPORT_REVIEW"] ?? "all"
        if mode == "prepare" {
            try await prepare(root)
            print("PASS: native fixtures prepared")
            return
        }
        let result = URL(fileURLWithPath: env["SCREENDROP_EXPORT_REVIEW_RESULT"] ?? path, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let config = configuration(root, mode: mode)
        let start = ProcessInfo.processInfo.systemUptime
        if mode == "cancel" || mode == "cancel-immediate" {
            let task = Task { try await RecordingStudioExporter().export(config, progress: { _ in }) }
            if mode == "cancel" { try await Task.sleep(for: .milliseconds(150)) }
            task.cancel()
            do {
                let url = try await task.value
                try? FileManager.default.removeItem(at: url)
                throw Failure.assertion("cancelled export returned success")
            } catch is CancellationError {
                print("PASS: cancellation propagated")
            }
            return
        }
        if mode == "invalid" {
            do {
                let url = try await RecordingStudioExporter().export(config, progress: { _ in })
                try? FileManager.default.removeItem(at: url)
                throw Failure.assertion("invalid source returned success")
            } catch let error as Failure { throw error }
            catch { print("PASS: invalid source rejected: \(error)"); return }
        }
        let output = try await RecordingStudioExporter().export(config, progress: { _ in })
        let wall = ProcessInfo.processInfo.systemUptime - start
        let destination = result.appendingPathComponent("export.\(config.exportSettings.effectiveContainer.fileExtension)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: output, to: destination)
        let stats = try await inspect(destination, duration: config.clipTimeline.duration,
                                      audio: !config.exportSettings.removeAudio,
                                      expectedSize: config.canvasSize)
        let report: [String: Any] = ["mode": mode, "wall_seconds": wall, "media": stats,
                                   "gpu": MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
                                   "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                   "depth": env["SCREENDROP_STUDIO_EXPORT_DEPTH"] ?? "default",
                                   "reuse": env["SCREENDROP_STUDIO_EXPORT_REUSE"] ?? "default",
                                   "text_cache": env["SCREENDROP_STUDIO_EXPORT_TEXT_CACHE"] ?? "default",
                                   "digest_enabled": env["SCREENDROP_STUDIO_EXPORT_DIGEST"] != nil]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: result.appendingPathComponent("result.json"))
        print("PASS: \(mode), \(wall)s, \(stats)")
    }

    private static func configuration(_ root: URL, mode: String) -> RecordingStudioExporter.Configuration {
        let bench = mode == "benchmark" || mode == "cancel" || mode == "cancel-immediate"
        let still = mode == "static" || bench
        let full = !still
        let clips = still ? RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0, sourceEnd: bench ? 30 : 4)])
            : RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0.25, sourceEnd: 2.25),
                                              RecordingClipSegment(sourceStart: 2.7, sourceEnd: 3.9, speed: 2)])
        var capture = PointerCaptureFile()
        capture.travel = (0...16).map { i in
            PointerTravelSample(time: Double(i) / 4, x: 0.15 + Double(i % 5) * 0.16, y: 0.2 + Double(i % 3) * 0.24)
        }
        if let imageData = try? Data(contentsOf: root.appendingPathComponent("pointer.png")) {
            capture.artwork = [PointerArtwork(artworkID: "fixture-arrow", imageData: imageData,
                anchorPoint: .init(x: 1, y: 1), referenceSize: .init(width: 24, height: 24))]
            for i in capture.travel.indices { capture.travel[i].artworkID = "fixture-arrow" }
        }
        capture.presses = [PointerPressEvent(time: 0.6, x: 0.3, y: 0.45, button: 0, phase: .down),
                           PointerPressEvent(time: 0.73, x: 0.3, y: 0.45, button: 0, phase: .up)]
        capture.keystrokes = [RecordingKeystrokeEvent(time: 0.35, modifiers: ["⌘", "⇧"], key: "K"),
                              RecordingKeystrokeEvent(time: 1.3, modifiers: ["⌃"], key: "⇥"),
                              RecordingKeystrokeEvent(time: 2.85, key: "esc")]
        let cues = [ZoomCue(start: 0.4, end: 1.8, zoom: 1.8, anchorMode: .pinnedAnchor,
                            pinnedPoint: CGPoint(x: 0.7, y: 0.32)),
                    ZoomCue(start: 2.8, end: 3.8, zoom: 1.35, anchorMode: .pointerAnchor)]
        let viewport = full ? ViewportTimeline.build(cues: cues, capture: capture, clipTimeline: clips) : .identity
        let pointer = full ? PointerTimeline.build(capture: capture, duration: 4,
                         recordingSizeInPoints: CGSize(width: 960, height: 540), clipTimeline: clips) : nil
        let subtitles = [RecordingSubtitleCue(start: 0.3, end: 2.1, text: "Sharp text, zooms and camera stay synchronized."),
                         RecordingSubtitleCue(start: 2.7, end: 4, text: "Second cut: café, 日本語, 42.")]
        let words = [RecordingTranscriptWord(text: "Sharp ", start: 0.3, end: 0.55),
                     RecordingTranscriptWord(text: "text, ", start: 0.55, end: 0.8),
                     RecordingTranscriptWord(text: "zooms ", start: 0.8, end: 1.1),
                     RecordingTranscriptWord(text: "and ", start: 1.1, end: 1.25),
                     RecordingTranscriptWord(text: "camera ", start: 1.25, end: 1.6),
                     RecordingTranscriptWord(text: "stay ", start: 1.6, end: 1.8),
                     RecordingTranscriptWord(text: "synchronized.", start: 1.8, end: 2.05),
                     RecordingTranscriptWord(text: "Second ", start: 2.7, end: 2.95),
                     RecordingTranscriptWord(text: "cut: ", start: 2.95, end: 3.15),
                     RecordingTranscriptWord(text: "café, ", start: 3.15, end: 3.4),
                     RecordingTranscriptWord(text: "日本語, ", start: 3.4, end: 3.65),
                     RecordingTranscriptWord(text: "42.", start: 3.65, end: 3.9)]
        let portrait = mode == "portrait" || mode == "fit"
        let size = bench ? CGSize(width: 1920, height: 1080) : (portrait ? CGSize(width: 360, height: 640) : CGSize(width: 960, height: 540))
        var style = RecordingStudioStyle()
        style.camera.isVisible = full
        style.camera.size = 0.25
        style.camera.center = CGPoint(x: 0.82, y: 0.73)
        style.camera.roundness = 0.5
        if mode == "wallpaper" {
            style.background = .customWallpaper(AnnotationCustomWallpaper(url: root.appendingPathComponent("wallpaper.png")))
        }
        var settings = VideoCompressionSettings()
        settings.codec = mode == "hevc" ? .hevc : .h264
        settings.container = mode == "hevc" || mode == "mov" ? .mov : .mp4
        settings.removeAudio = mode == "mute" || still
        let reframe = mode == "portrait" ? ReframeTrack.build(preset: .vertical9x16,
                sourceSize: CGSize(width: 960, height: 540), viewportTimeline: viewport,
                duration: clips.duration, focus: { pointer?.location(at: $0) }) : nil
        return RecordingStudioExporter.Configuration(
            screenURL: root.appendingPathComponent(mode == "invalid" ? "missing.mov" : (still ? "static.mov" : "source.mov")),
            cameraURL: full ? root.appendingPathComponent("camera.mov") : nil,
            cameraOffset: 0.17, style: style, viewportTimeline: viewport, pointerTimeline: pointer,
            showsPressEffects: full, keystrokeTimeline: full ? KeystrokeCaptionTimeline(events: capture.keystrokes) : nil,
            keystrokePlacement: .bottomLeft, subtitleTimeline: full ? SubtitleTimeline(cues: subtitles) : nil,
            subtitleStyle: SubtitleBarStyle(verticalPosition: 0.6, fontScale: 1.1, highlightsSpokenWord: mode != "plain"),
            karaokeTimeline: full ? KaraokeTimeline(cues: subtitles, words: words) : nil,
            canvasSize: size,
            videoCropRect: mode == "crop" ? CGRect(x: 0.1, y: 0.12, width: 0.75, height: 0.7) : CGRect(x: 0, y: 0, width: 1, height: 1),
            clipTimeline: clips, exportSettings: settings,
            audioReplacementURL: mode == "replacement" ? root.appendingPathComponent("replacement.wav") : nil,
            reframe: reframe, fitContentAspect: mode == "fit" ? 16.0 / 9.0 : nil)
    }

    private static func prepare(_ root: URL) async throws {
        try await movie(root.appendingPathComponent("screen.mov"), width: 960, height: 540, duration: 4, step: 0.25)
        try await movie(root.appendingPathComponent("camera.mov"), width: 320, height: 240, duration: 4, step: 1.0 / 15)
        try await movie(root.appendingPathComponent("static.mov"), width: 960, height: 540, duration: 30, step: 30)
        try wav(root.appendingPathComponent("audio.wav"), duration: 4, frequency: 440)
        try wav(root.appendingPathComponent("replacement.wav"), duration: 1.5, frequency: 660)
        let composition = AVMutableComposition()
        let video = AVURLAsset(url: root.appendingPathComponent("screen.mov"))
        let audio = AVURLAsset(url: root.appendingPathComponent("audio.wav"))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600))
        guard let vt = try await video.loadTracks(withMediaType: .video).first,
              let at = try await audio.loadTracks(withMediaType: .audio).first,
              let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.assertion("fixture tracks unavailable")
        }
        try v.insertTimeRange(range, of: vt, at: .zero)
        try a.insertTimeRange(range, of: at, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.assertion("fixture muxer unavailable")
        }
        try await exporter.export(to: root.appendingPathComponent("source.mov"), as: .mov)
        let image = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSColor.systemIndigo.setFill(); rect.fill()
            NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 45, dy: 15)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw Failure.assertion("wallpaper") }
        try png.write(to: root.appendingPathComponent("wallpaper.png"))
        guard let arrowTIFF = NSCursor.arrow.image.tiffRepresentation,
              let arrowRep = NSBitmapImageRep(data: arrowTIFF),
              let arrowPNG = arrowRep.representation(using: .png, properties: [:]) else {
            throw Failure.assertion("pointer artwork")
        }
        try arrowPNG.write(to: root.appendingPathComponent("pointer.png"))
    }

    private static func movie(_ url: URL, width: Int, height: Int, duration: Double, step: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                    AVVideoWidthKey: width, AVVideoHeightKey: height])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
        try require(writer.startWriting(), "fixture writer failed")
        writer.startSession(atSourceTime: .zero)
        let count = max(1, Int((duration / step).rounded(.up)))
        for index in 0..<count {
            while !input.isReadyForMoreMediaData {
                try require(writer.status == .writing, "fixture writer stopped: \(String(describing: writer.error))")
                try await Task.sleep(for: .milliseconds(1))
            }
            try autoreleasepool {
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool else { throw Failure.assertion("fixture pool") }
                try require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, "fixture allocation")
                guard let buffer else { throw Failure.assertion("nil fixture frame") }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw Failure.assertion("fixture context")
                }
                context.setFillColor(CGColor(red: 0.14, green: 0.21, blue: 0.32, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setStrokeColor(CGColor(gray: 0.9, alpha: 1)); context.setLineWidth(1)
                for x in stride(from: 10, to: width, by: 13) {
                    context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height)); context.strokePath()
                }
                context.setFillColor(CGColor(red: Double(index % 7) / 7, green: 0.65, blue: 0.4, alpha: 1))
                context.fillEllipse(in: CGRect(x: 30 + index * 7 % (width / 2), y: 40, width: width / 3, height: height / 2))
                let font = CTFontCreateWithName("Helvetica" as CFString, 19, nil)
                let text = NSAttributedString(string: "Frame \(index) / sharp 0123456789", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
                context.textPosition = CGPoint(x: 30, y: height - 35)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
                try require(adaptor.append(buffer, withPresentationTime: CMTime(seconds: Double(index) * step, preferredTimescale: 600)), "fixture append")
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "fixture finalization: \(String(describing: writer.error))")
    }

    private static func wav(_ url: URL, duration: Double, frequency: Double) throws {
        let rate = 48_000, frames = Int(duration * 48_000)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + frames * 4)); text("WAVEfmt "); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16); text("data"); u32(UInt32(frames * 4))
        for frame in 0..<frames {
            let sample = Int16(sin(Double(frame) * 2 * .pi * frequency / Double(rate)) * 8_000)
            u16(UInt16(bitPattern: sample)); u16(UInt16(bitPattern: sample))
        }
        try data.write(to: url)
    }

    private static func inspect(_ url: URL, duration: Double, audio: Bool, expectedSize: CGSize) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.assertion("no exported video") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try require(audioTracks.isEmpty != audio, "audio track presence mismatch")
        let size = try await video.load(.naturalSize)
        try require(size == expectedSize, "output size mismatch \(size) vs \(expectedSize)")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try require(reader.startReading(), "readback did not start")
        var frames = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let sample = output.copyNextSampleBuffer() else { return false }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Match the established writer's actual CMTime conversion. Core
            // Media can truncate a floating-point value by one 600-timescale
            // tick (pass1 frame 11 is 109/600, not 110/600).
            let expectedTime = CMTime(seconds: Double(frames) / 60, preferredTimescale: 600).seconds
            try require(abs(time - expectedTime) < 0.000_001, "PTS drift at frame \(frames): \(time) vs \(expectedTime)")
            frames += 1
            return true
        }) {}
        try require(reader.status == .completed, "readback failed")
        try require(frames == Int((duration * 60).rounded()), "frame count \(frames) vs \(duration * 60)")
        let actualDuration = try await asset.load(.duration).seconds
        try require(abs(actualDuration - duration) < 0.08, "duration drift \(actualDuration) vs \(duration)")
        var audioFrames: Int64 = 0
        if let audioTrack = audioTracks.first {
            let audioReader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            audioReader.add(audioOutput); try require(audioReader.startReading(), "audio readback did not start")
            while let sample = audioOutput.copyNextSampleBuffer() { audioFrames += Int64(CMSampleBufferGetNumSamples(sample)) }
            try require(audioReader.status == .completed && audioFrames > 0, "audio decoding failed")
        }
        return ["frames": frames, "duration_seconds": actualDuration, "audio_tracks": audioTracks.count,
                "decoded_audio_samples": audioFrames, "width": size.width, "height": size.height]
    }
}
#endif
