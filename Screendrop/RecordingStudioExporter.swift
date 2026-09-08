//
//  RecordingStudioExporter.swift
//  Screendrop
//
//  Offline compositor for studio exports: decodes the screen (and camera)
//  recordings frame by frame, draws each frame through the same
//  RecordingStudioLayout / ViewportTimeline math the live preview
//  uses, and writes a new HEVC movie. Audio tracks (system + microphone)
//  are mixed and passed through on the unchanged timeline, unless the
//  project imported a soundtrack to replace them.
//
//  Everything static - the background fill and the card shadow - is
//  rendered once into a backdrop image; per frame the work is one backdrop
//  blit plus the clipped video draws.
//

import AppKit
import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import Dispatch
import Foundation
import ImageIO
import SwiftUI

nonisolated private final class StudioExportBenchmark: @unchecked Sendable {
    #if DEBUG
    private static let logLock = NSLock()
    private static let logURL: URL = {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Screendrop", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("DevExportBenchmarks.log")
    }()

    private let lock = NSLock()
    private var backend: String
    private var filter = "none"
    private var accumulation = "none"
    private var outputURL = "unknown"
    private var outputWidth = 0
    private var outputHeight = 0
    private var sourceDuration = 0.0
    private var frames = 0
    private var renderSeconds = 0.0
    private var writerWaitSeconds = 0.0
    private var blurSamplesTotal = 0
    private var blurSamplesMax = 0
    private var blurredFrames = 0
    private var stages: [String: Double] = [:]
    private var reusedFrames = 0
    private var peakSlots = 0
    #endif

    init(backend: String) {
        #if DEBUG
        self.backend = backend
        #endif
    }

    func setBackend(_ backend: String) {
        #if DEBUG
        lock.withLock {
            self.backend = backend
        }
        #endif
    }

    func setFilter(_ filter: String) {
        #if DEBUG
        lock.withLock {
            self.filter = filter
        }
        #endif
    }

    func setAccumulation(_ accumulation: String) {
        #if DEBUG
        lock.withLock {
            self.accumulation = accumulation
        }
        #endif
    }

    func setOutputInfo(width: Int, height: Int, sourceDuration: Double) {
        #if DEBUG
        lock.withLock {
            outputWidth = width
            outputHeight = height
            self.sourceDuration = sourceDuration
        }
        #endif
    }

    func setOutputURL(_ url: URL) {
        #if DEBUG
        lock.withLock {
            outputURL = url.path
        }
        #endif
    }

    func recordFrame(blurSampleCount: Int) {
        #if DEBUG
        lock.withLock {
            frames += 1
            blurSamplesTotal += blurSampleCount
            blurSamplesMax = max(blurSamplesMax, blurSampleCount)
            if blurSampleCount > 1 {
                blurredFrames += 1
            }
        }
        #endif
    }

    func recordRender(seconds: Double) {
        #if DEBUG
        lock.withLock {
            renderSeconds += seconds
        }
        #endif
    }

    func recordWriterWait(seconds: Double) {
        #if DEBUG
        lock.withLock {
            writerWaitSeconds += seconds
        }
        #endif
    }

    func recordStage(_ name: String, seconds: Double) {
        #if DEBUG
        lock.withLock { stages[name, default: 0] += seconds }
        #endif
    }

    func recordReuse() {
        #if DEBUG
        lock.withLock { reusedFrames += 1 }
        #endif
    }

    func recordSlots(_ count: Int) {
        #if DEBUG
        lock.withLock { peakSlots = max(peakSlots, count) }
        #endif
    }

    func printSummary(wallClockSeconds: Double) {
        #if DEBUG
        let snapshot = lock.withLock {
            (
                backend: backend,
                filter: filter,
                accumulation: accumulation,
                outputURL: outputURL,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                sourceDuration: sourceDuration,
                frames: frames,
                renderSeconds: renderSeconds,
                writerWaitSeconds: writerWaitSeconds,
                blurSamplesTotal: blurSamplesTotal,
                blurSamplesMax: blurSamplesMax,
                blurredFrames: blurredFrames
            )
        }
        let averageBlurSamples = snapshot.frames > 0
            ? Double(snapshot.blurSamplesTotal) / Double(snapshot.frames)
            : 0

        let extra = lock.withLock {
            "pipeline_depth=\(StudioExportPipelineOptions.depth)\n"
                + "peak_slots=\(peakSlots)\nreused_frames=\(reusedFrames)\n"
                + stages.keys.sorted().map { "\($0)=\(stages[$0] ?? 0)" }.joined(separator: "\n")
        }
        let summary = """
        [Screendrop Export Benchmark]
        timestamp=\(ISO8601DateFormatter().string(from: Date()))
        backend=\(snapshot.backend)
        filter=\(snapshot.filter)
        accumulation=\(snapshot.accumulation)
        output=\(snapshot.outputURL)
        output_size=\(snapshot.outputWidth)x\(snapshot.outputHeight)
        source_duration=\(snapshot.sourceDuration)
        duration=\(wallClockSeconds)
        frames=\(snapshot.frames)
        render_seconds=\(snapshot.renderSeconds)
        writer_wait_seconds=\(snapshot.writerWaitSeconds)
        blur_samples_total=\(snapshot.blurSamplesTotal)
        blur_samples_avg=\(averageBlurSamples)
        blur_samples_max=\(snapshot.blurSamplesMax)
        blurred_frames=\(snapshot.blurredFrames)
        \(extra)
        """
        print(summary)
        // GUI launches can keep stdout buffered for the lifetime of the app;
        // stderr makes DEBUG benchmark results observable without requiring
        // the app to quit.
        let data = Data((summary + "\n").utf8)
        FileHandle.standardError.write(data)
        Self.logLock.withLock {
            if let handle = try? FileHandle(forWritingTo: Self.logURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: Self.logURL, options: .atomic)
            }
        }
        #endif
    }
}

nonisolated final class RecordingStudioExporter: @unchecked Sendable {
    /// Fixed output cadence for both the writer's frame clock and the
    /// compositor's motion-blur shutter - kept as one constant so they can
    /// never drift apart.
    private static let outputFrameRate: Double = 60

    struct Configuration: Sendable {
        let screenURL: URL
        let cameraURL: URL?
        let cameraOffset: TimeInterval
        let style: RecordingStudioStyle
        let viewportTimeline: ViewportTimeline
        /// Non-nil when the capture hid the OS cursor and the export must
        /// draw the synthetic pointer along this smoothed timeline.
        let pointerTimeline: PointerTimeline?
        let showsPressEffects: Bool
        /// Non-nil when recorded keystroke chords should be captioned.
        let keystrokeTimeline: KeystrokeCaptionTimeline?
        let keystrokePlacement: RecordingKeystrokePlacement
        /// Non-nil when transcribed narration should be subtitled.
        let subtitleTimeline: SubtitleTimeline?
        let subtitleStyle: SubtitleBarStyle
        /// Word timings behind the subtitles, for karaoke highlighting.
        let karaokeTimeline: KaraokeTimeline?
        let canvasSize: CGSize
        /// Normalized top-left crop of the screen-video source.
        let videoCropRect: CGRect
        let clipTimeline: RecordingClipTimeline
        let exportSettings: VideoCompressionSettings
        /// Non-nil when an imported soundtrack stands in for the recorded
        /// audio. It is already the finished cut's audio, so it plays flat
        /// from zero instead of being re-cut through the clip timeline.
        let audioReplacementURL: URL?
        /// Non-nil when exporting into a different aspect ratio; drives the
        /// crop-and-follow virtual camera in place of the zoom viewport.
        let reframe: ReframeTrack?
        /// Non-nil when exporting into a different aspect ratio in Fit
        /// mode: the whole recording shows in a content-aspect card and
        /// the background fills the rest. Mutually exclusive with
        /// `reframe`.
        let fitContentAspect: CGFloat?

        init(
            screenURL: URL,
            cameraURL: URL?,
            cameraOffset: TimeInterval,
            style: RecordingStudioStyle,
            viewportTimeline: ViewportTimeline,
            pointerTimeline: PointerTimeline?,
            showsPressEffects: Bool,
            keystrokeTimeline: KeystrokeCaptionTimeline?,
            keystrokePlacement: RecordingKeystrokePlacement,
            subtitleTimeline: SubtitleTimeline?,
            subtitleStyle: SubtitleBarStyle,
            karaokeTimeline: KaraokeTimeline? = nil,
            canvasSize: CGSize,
            videoCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
            clipTimeline: RecordingClipTimeline,
            exportSettings: VideoCompressionSettings,
            audioReplacementURL: URL? = nil,
            reframe: ReframeTrack? = nil,
            fitContentAspect: CGFloat? = nil
        ) {
            self.screenURL = screenURL
            self.cameraURL = cameraURL
            self.cameraOffset = cameraOffset
            self.style = style
            self.viewportTimeline = viewportTimeline
            self.pointerTimeline = pointerTimeline
            self.showsPressEffects = showsPressEffects
            self.keystrokeTimeline = keystrokeTimeline
            self.keystrokePlacement = keystrokePlacement
            self.subtitleTimeline = subtitleTimeline
            self.subtitleStyle = subtitleStyle
            self.karaokeTimeline = karaokeTimeline
            self.canvasSize = canvasSize
            self.videoCropRect = videoCropRect
            self.clipTimeline = clipTimeline
            self.exportSettings = exportSettings
            self.audioReplacementURL = audioReplacementURL
            self.reframe = reframe
            self.fitContentAspect = fitContentAspect
        }
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case writerFailed(Error?)
        case pixelBufferAllocationFailed(CVReturn)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                "The recording has no video track."
            case .writerFailed(let error):
                error?.localizedDescription ?? "Writing the exported video failed."
            case .pixelBufferAllocationFailed(let status):
                "Could not allocate an export frame (Core Video status \(status))."
            case .cancelled:
                "Export cancelled."
            }
        }
    }

    private typealias CancelFlag = StudioExportControl

    func export(
        _ configuration: Configuration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cancelFlag = CancelFlag()
        // A user-requested long export must not be suspended by App Nap or
        // idle system sleep. Display sleep remains independent.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Exporting the recording requested by the user"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        return try await withTaskCancellationHandler {
            try await run(configuration, cancelFlag: cancelFlag, progress: progress)
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    private func run(
        _ configuration: Configuration,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let benchmark = StudioExportBenchmark(
            backend: StudioScreenRenderBackend.configured.rawValue
        )
        #if DEBUG
        let exportStartedAt = ProcessInfo.processInfo.systemUptime
        defer {
            benchmark.printSummary(
                wallClockSeconds: ProcessInfo.processInfo.systemUptime - exportStartedAt
            )
        }
        #endif

        let sourceAsset = AVURLAsset(url: configuration.screenURL)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        let clipTimeline = configuration.clipTimeline.normalized(to: sourceDuration)
        guard clipTimeline.duration >= RecordingClipSegment.minimumDuration else {
            throw VideoTrimExportError.invalidRange
        }
        let screenAsset = try RecordingCompositionBuilder.makeAsset(
            from: sourceAsset,
            timeline: clipTimeline,
            sourceDuration: sourceDuration
        )
        guard let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTracks = try await screenAsset.loadTracks(withMediaType: .audio)
        let exportStartTime = CMTime.zero
        let exportTimeRange = CMTimeRange(
            start: exportStartTime,
            duration: CMTime(seconds: clipTimeline.duration, preferredTimescale: 600)
        )

        let outputSize = Self.outputSize(
            source: configuration.canvasSize,
            resolution: configuration.exportSettings.resolution
        )
        let canvasWidth = max(2, Int(outputSize.width.rounded()) & ~1)
        let canvasHeight = max(2, Int(outputSize.height.rounded()) & ~1)
        let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)
        benchmark.setOutputInfo(
            width: canvasWidth,
            height: canvasHeight,
            sourceDuration: clipTimeline.duration
        )

        // Readers
        let screenReader = try AVAssetReader(asset: screenAsset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        screenReader.add(videoOutput)
        screenReader.timeRange = exportTimeRange

        // An imported soundtrack replaces the recorded one wholesale, and it
        // needs its own reader: it is a different file, already carrying the
        // finished cut's timing, so it plays straight through from zero
        // while the screen reader stays on the composed video.
        var audioOutput: AVAssetReaderAudioMixOutput?
        var replacementReader: AVAssetReader?
        if !configuration.exportSettings.removeAudio {
            if let replacementURL = configuration.audioReplacementURL {
                let replacementAsset = AVURLAsset(url: replacementURL)
                let replacementTracks = try await replacementAsset.loadTracks(withMediaType: .audio)
                if !replacementTracks.isEmpty {
                    let reader = try AVAssetReader(asset: replacementAsset)
                    // Clamps a soundtrack that overruns the cut; a shorter
                    // one simply leaves the tail silent.
                    reader.timeRange = exportTimeRange
                    let output = AVAssetReaderAudioMixOutput(
                        audioTracks: replacementTracks,
                        audioSettings: nil
                    )
                    output.alwaysCopiesSampleData = false
                    reader.add(output)
                    replacementReader = reader
                    audioOutput = output
                }
            } else if !audioTracks.isEmpty {
                let output = AVAssetReaderAudioMixOutput(
                    audioTracks: audioTracks,
                    audioSettings: nil
                )
                output.alwaysCopiesSampleData = false
                screenReader.add(output)
                audioOutput = output
            }
        }

        let cameraFeed = try await CameraFrameFeed(
            url: configuration.cameraURL,
            offset: configuration.cameraOffset
        )
        defer { cameraFeed?.cancel() }

        // Writer
        let container = configuration.exportSettings.effectiveContainer
        let outputURL = Self.temporaryOutputURL(container: container)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: container.fileType)
        var exportSucceeded = false
        let capturedReplacementReader = replacementReader
        defer {
            if screenReader.status == .reading { screenReader.cancelReading() }
            if capturedReplacementReader?.status == .reading { capturedReplacementReader?.cancelReading() }
            if !exportSucceeded {
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        // Wake readers immediately. Writer cancellation happens only after
        // BOTH pumps have exited, so it cannot race a late append.
        let readerCancellation = StudioExportReaderCancellation(
            readers: [screenReader] + (capturedReplacementReader.map { [$0] } ?? [])
        )
        let ioCancellation = cancelFlag.onFailure {
            readerCancellation.cancel()
            cameraFeed?.cancel()
        }
        defer { cancelFlag.removeHandler(ioCancellation) }
        try cancelFlag.check()
        // Faststart puts the index ahead of the media so a shared link plays
        // before it finishes downloading. The writer pays for that with an
        // extra pass at the end, so only MP4 - the container people actually
        // stream - opts in.
        writer.shouldOptimizeForNetworkUse = container.supportsFastStart

        let codec: AVVideoCodecType = configuration.exportSettings.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: canvasWidth,
            AVVideoHeightKey: canvasHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.averageBitRate(
                    width: canvasWidth,
                    height: canvasHeight,
                    quality: configuration.exportSettings.quality
                ),
                AVVideoExpectedSourceFrameRateKey: 60
            ] as [String: Any]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: canvasWidth,
                kCVPixelBufferHeightKey as String: canvasHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        try cancelFlag.check()
        guard screenReader.startReading() else {
            throw screenReader.error ?? ExportError.writerFailed(nil)
        }
        if let replacementReader, !replacementReader.startReading() {
            screenReader.cancelReading()
            throw replacementReader.error ?? ExportError.writerFailed(nil)
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: exportStartTime)

        let includeBubble = cameraFeed != nil
        let compositor = await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.screendrop.studio.export.prepare", qos: .userInitiated).async {
                let compositor = StudioFrameCompositor(
                    canvasSize: canvasSize,
                    videoCropRect: configuration.videoCropRect,
                    style: configuration.style,
                    viewportTimeline: configuration.viewportTimeline,
                    pointerTimeline: configuration.pointerTimeline,
                    showsPressEffects: configuration.showsPressEffects,
                    keystrokeTimeline: configuration.keystrokeTimeline,
                    keystrokePlacement: configuration.keystrokePlacement,
                    subtitleTimeline: configuration.subtitleTimeline,
                    subtitleStyle: configuration.subtitleStyle,
                    karaokeTimeline: configuration.karaokeTimeline,
                    includeBubble: includeBubble,
                    outputFrameInterval: 1 / Self.outputFrameRate,
                    benchmark: benchmark,
                    reframe: configuration.reframe,
                    fitContentAspect: configuration.fitContentAspect
                )
                continuation.resume(returning: compositor)
            }
        }

        let screenAudioOutput = audioOutput
        let writerAudioInput = audioInput

        do {
            async let videoDone: Void = pumpVideo(
                output: videoOutput,
                reader: screenReader,
                writer: writer,
                input: videoInput,
                adaptor: adaptor,
                compositor: compositor,
                cameraFeed: cameraFeed,
                clipTimeline: clipTimeline,
                cancelFlag: cancelFlag,
                benchmark: benchmark,
                progress: progress
            )
            async let audioDone: Void = pumpAudio(
                output: screenAudioOutput,
                reader: capturedReplacementReader ?? screenReader,
                writer: writer,
                input: writerAudioInput,
                cancelFlag: cancelFlag
            )
            _ = try await (videoDone, audioDone)
        } catch {
            throw cancelFlag.failure ?? error
        }

        try cancelFlag.check()
        #if DEBUG
        let finishStartedAt = ProcessInfo.processInfo.systemUptime
        #endif
        try await StudioExportWriterFinisher(writer: writer, control: cancelFlag).finish()
        #if DEBUG
        benchmark.recordStage("finalize_seconds", seconds: ProcessInfo.processInfo.systemUptime - finishStartedAt)
        #endif
        try cancelFlag.check()
        exportSucceeded = true
        benchmark.setOutputURL(outputURL)
        progress(1)
        return outputURL
    }

    private func pumpVideo(
        output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        compositor: StudioFrameCompositor,
        cameraFeed: CameraFrameFeed?,
        clipTimeline: RecordingClipTimeline,
        cancelFlag: CancelFlag,
        benchmark: StudioExportBenchmark,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // AVAssetReader, Core Graphics and oldest-slot GPU waits are blocking.
        // A dedicated worker avoids blocking a Swift concurrency worker thread.
        let queue = DispatchQueue(label: "com.screendrop.studio.export.video", qos: .userInitiated,
                                  autoreleaseFrequency: .workItem)
        let io = StudioExportVideoIO(output: output, reader: reader, writer: writer,
                                     input: input, adaptor: adaptor)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.pumpVideoOnWorker(output: io.output, reader: io.reader, writer: io.writer,
                        input: io.input, adaptor: io.adaptor, compositor: compositor, cameraFeed: cameraFeed,
                        clipTimeline: clipTimeline, cancelFlag: cancelFlag,
                        benchmark: benchmark, progress: progress)
                    continuation.resume()
                } catch {
                    // Fail and wake the sibling BEFORE resuming this task.
                    // Waiting until the async-let scope exits can deadlock it.
                    cancelFlag.fail(error)
                    continuation.resume(throwing: cancelFlag.failure ?? error)
                }
            }
        }
    }

    private func pumpVideoOnWorker(
        output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        compositor: StudioFrameCompositor,
        cameraFeed: CameraFrameFeed?,
        clipTimeline: RecordingClipTimeline,
        cancelFlag: CancelFlag,
        benchmark: StudioExportBenchmark,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let wake = StudioExportWakeSignal()
        let observation = input.observe(\.isReadyForMoreMediaData, options: [.new]) { _, _ in wake.signal() }
        let cancellation = cancelFlag.onFailure { wake.signal() }
        defer {
            observation.invalidate()
            cancelFlag.removeHandler(cancellation)
        }
        let clipIndex = StudioExportClipIndex(clipTimeline)
        let frameRate = Self.outputFrameRate
        // Preserve the exact established frame count and 600-timescale PTS.
        let frameCount = max(1, Int((clipIndex.duration * frameRate).rounded()))
        #if DEBUG
        let frameProbe = try StudioExportFrameProbe.make()
        #endif
        let depth = StudioExportPipelineOptions.depth
        let permitsReuse = compositor.permitsFrameReuse
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writerFailed(writer.error) }

        func nextSourceFrame() throws -> (buffer: CVPixelBuffer, time: TimeInterval)? {
            #if DEBUG
            let started = ProcessInfo.processInfo.systemUptime
            defer { benchmark.recordStage("decode_screen_seconds", seconds: ProcessInfo.processInfo.systemUptime - started) }
            #endif
            return try autoreleasepool {
                try cancelFlag.check()
                while let sample = output.copyNextSampleBuffer() {
                    guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
                    return (image, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
                try Self.checkReader(reader, control: cancelFlag)
                return nil
            }
        }

        var currentBuffer: CVPixelBuffer?
        var pendingSource = try nextSourceFrame()
        guard pendingSource != nil else { throw ExportError.noVideoTrack }
        var previousClipID: UUID?
        var nextFrameIndex = 0
        var slots: [StudioExportFrameSlot] = []
        slots.reserveCapacity(depth)
        var previousVisual: StudioExportVisualFrame?

        func prepareNextFrame() throws -> StudioExportFrameSlot {
            try cancelFlag.check()
            let index = nextFrameIndex
            let editorTime = Double(index) / frameRate
            guard let location = clipIndex.location(at: editorTime) else {
                throw ExportError.writerFailed(nil)
            }
            let sourceTime = location.sourceTime
            if previousClipID != location.segmentID {
                if previousClipID != nil { currentBuffer = nil }
                previousClipID = location.segmentID
            }
            // Hold sparse frames, including the established early-first-frame
            // behavior. Never carry a held screen frame across a hard cut.
            while let sample = pendingSource, sample.time <= editorTime {
                currentBuffer = sample.buffer
                pendingSource = try nextSourceFrame()
            }
            guard let source = currentBuffer ?? pendingSource?.buffer else {
                throw ExportError.noVideoTrack
            }
            #if DEBUG
            let cameraStarted = ProcessInfo.processInfo.systemUptime
            #endif
            let camera = try cameraFeed?.latestFrame(at: sourceTime)
            #if DEBUG
            benchmark.recordStage("decode_camera_seconds", seconds: ProcessInfo.processInfo.systemUptime - cameraStarted)
            let prepareStarted = ProcessInfo.processInfo.systemUptime
            defer {
                let seconds = ProcessInfo.processInfo.systemUptime - prepareStarted
                benchmark.recordStage("prepare_cpu_seconds", seconds: seconds)
                benchmark.recordRender(seconds: seconds)
            }
            #endif
            let state = compositor.visualState(screenFrame: source, cameraFrame: camera,
                                               editorTime: editorTime, sourceTime: sourceTime)
            let visual: StudioExportVisualFrame
            if permitsReuse, let previousVisual, previousVisual.state == state {
                // The same immutable output buffer can be appended at a new
                // PTS. This skips rendering, NEVER an output frame or effect.
                visual = previousVisual
                benchmark.recordReuse()
            } else {
                var destination: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
                guard status == kCVReturnSuccess, let destination else {
                    throw ExportError.pixelBufferAllocationFailed(status)
                }
                let submission = try compositor.prepareScreen(frameIndex: index, state: state,
                    editorTime: editorTime, sourceTime: sourceTime, into: destination)
                visual = StudioExportVisualFrame(state: state, buffer: destination, submission: submission,
                                                editorTime: editorTime, sourceTime: sourceTime)
                previousVisual = visual
            }
            nextFrameIndex += 1
            return StudioExportFrameSlot(index: index, editorTime: editorTime,
                                         sourceTime: sourceTime, visual: visual)
        }

        while nextFrameIndex < frameCount || !slots.isEmpty {
            try cancelFlag.check()
            while slots.count < depth && nextFrameIndex < frameCount {
                let slot = try autoreleasepool { try prepareNextFrame() }
                slots.append(slot)
                benchmark.recordSlots(slots.count)
            }
            let slot = slots.removeFirst() // bounded to at most three entries
            try autoreleasepool {
                let visual = slot.visual
                if !visual.overlaysFinished {
                    #if DEBUG
                    let gpuWaitStarted = ProcessInfo.processInfo.systemUptime
                    #endif
                    try visual.submission?.waitUntilCompleted()
                    #if DEBUG
                    let wait = ProcessInfo.processInfo.systemUptime - gpuWaitStarted
                    benchmark.recordStage("gpu_wait_seconds", seconds: wait)
                    benchmark.recordStage("gpu_execution_seconds", seconds: visual.submission?.gpuSeconds ?? 0)
                    benchmark.recordRender(seconds: wait)
                    let overlaysStarted = ProcessInfo.processInfo.systemUptime
                    #endif
                    try cancelFlag.check()
                    try compositor.finishOverlays(cameraFrame: visual.state.cameraFrame,
                        editorTime: visual.editorTime, sourceTime: visual.sourceTime, into: visual.buffer)
                    visual.overlaysFinished = true
                    #if DEBUG
                    let overlays = ProcessInfo.processInfo.systemUptime - overlaysStarted
                    benchmark.recordStage("overlay_cpu_seconds", seconds: overlays)
                    benchmark.recordRender(seconds: overlays)
                    #endif
                }
                #if DEBUG
                let writerWaitStarted = ProcessInfo.processInfo.systemUptime
                #endif
                try Self.waitForWriter(input, writer: writer, control: cancelFlag, wake: wake)
                #if DEBUG
                benchmark.recordWriterWait(seconds: ProcessInfo.processInfo.systemUptime - writerWaitStarted)
                let appendStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let pts = CMTime(seconds: slot.editorTime, preferredTimescale: 600)
                #if DEBUG
                try frameProbe?.record(visual.buffer, index: slot.index, time: pts)
                #endif
                guard adaptor.append(visual.buffer, withPresentationTime: pts) else {
                    throw ExportError.writerFailed(writer.error)
                }
                #if DEBUG
                benchmark.recordStage("append_seconds", seconds: ProcessInfo.processInfo.systemUptime - appendStarted)
                #endif
                if slot.index % 10 == 0 { progress(min(0.98, Double(slot.index) / Double(frameCount))) }
            }
        }
        try Self.checkReader(reader, control: cancelFlag)
        input.markAsFinished()
    }

    private func pumpAudio(
        output: AVAssetReaderAudioMixOutput?,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        input: AVAssetWriterInput?,
        cancelFlag: CancelFlag
    ) async throws {
        guard let output, let input else { return }
        let queue = DispatchQueue(label: "com.screendrop.studio.export.audio", qos: .userInitiated,
                                  autoreleaseFrequency: .workItem)
        let io = StudioExportAudioIO(output: output, reader: reader, writer: writer, input: input)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                let wake = StudioExportWakeSignal()
                let observation = io.input.observe(\.isReadyForMoreMediaData, options: [.new]) { _, _ in wake.signal() }
                let cancellation = cancelFlag.onFailure { wake.signal() }
                defer {
                    observation.invalidate()
                    cancelFlag.removeHandler(cancellation)
                }
                do {
                    while try autoreleasepool(invoking: { () throws -> Bool in
                        try cancelFlag.check()
                        // Discover EOF before waiting for readiness. Otherwise
                        // an exhausted audio track can stall video interleaving.
                        guard let sample = io.output.copyNextSampleBuffer() else {
                            try Self.checkReader(io.reader, control: cancelFlag)
                            return false
                        }
                        try Self.waitForWriter(io.input, writer: io.writer, control: cancelFlag, wake: wake)
                        try cancelFlag.check()
                        guard io.input.append(sample) else { throw ExportError.writerFailed(io.writer.error) }
                        return true
                    }) {}
                    io.input.markAsFinished()
                    continuation.resume()
                } catch {
                    cancelFlag.fail(error)
                    continuation.resume(throwing: cancelFlag.failure ?? error)
                }
            }
        }
    }

    private static func waitForWriter(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        control: StudioExportControl,
        wake: StudioExportWakeSignal
    ) throws {
        try wake.waitUntil {
            try control.check()
            guard writer.status == .writing else { throw ExportError.writerFailed(writer.error) }
            return input.isReadyForMoreMediaData
        }
    }

    private static func checkReader(_ reader: AVAssetReader, control: StudioExportControl) throws {
        try control.check()
        if reader.status == .failed || reader.status == .cancelled {
            throw reader.error ?? ExportError.writerFailed(nil)
        }
    }

    private static func temporaryOutputURL(container: VideoExportContainer) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop", isDirectory: true)
            .appendingPathComponent("StudioExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).\(container.fileExtension)")
    }

    private static func outputSize(
        source: CGSize,
        resolution: VideoCompressionResolution
    ) -> CGSize {
        guard source.width > 0, source.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        let requestedHeight: CGFloat?
        switch resolution {
        case .original: requestedHeight = nil
        case .p1080: requestedHeight = 1080
        case .p720: requestedHeight = 720
        case .p480: requestedHeight = 480
        }
        guard let requestedHeight, source.height > requestedHeight else { return source }
        return CGSize(
            width: source.width * requestedHeight / source.height,
            height: requestedHeight
        )
    }

    private static func averageBitRate(
        width: Int,
        height: Int,
        quality: VideoCompressionQuality
    ) -> Int {
        let factor: Double
        switch quality {
        case .high: factor = 3.2
        case .medium: factor = 2.1
        case .low: factor = 1.25
        }
        return max(2_500_000, Int(Double(width * height) * factor))
    }
}

// MARK: - Legacy AVFoundation worker ownership

/// AVFoundation's legacy writer/reader types lack Sendable conformances.
/// These narrowly scoped handles document the manual ownership contract:
/// each output and writer input has exactly one dedicated worker. Shared
/// reader cancellation/status and writer status are the only cross-worker
/// operations. Finalization starts only after both workers have returned.
/// The boxes do NOT make arbitrary concurrent append/read operations safe.
nonisolated private struct StudioExportVideoIO: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}

nonisolated private struct StudioExportAudioIO: @unchecked Sendable {
    let output: AVAssetReaderAudioMixOutput
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
}

/// Cancellation deliberately crosses the reader workers; it never consumes
/// a sample or mutates their cursor state. Keep this exception explicit.
nonisolated private struct StudioExportReaderCancellation: @unchecked Sendable {
    let readers: [AVAssetReader]
    func cancel() {
        for reader in readers where reader.status == .reading { reader.cancelReading() }
    }
}

// MARK: - Bounded frame ownership

nonisolated private final class StudioExportVisualFrame {
    let state: StudioFrameCompositor.VisualState
    let buffer: CVPixelBuffer
    let submission: MetalStudioScreenRenderer.Submission?
    let editorTime: TimeInterval
    let sourceTime: TimeInterval
    var overlaysFinished = false

    init(state: StudioFrameCompositor.VisualState, buffer: CVPixelBuffer,
         submission: MetalStudioScreenRenderer.Submission?, editorTime: TimeInterval, sourceTime: TimeInterval) {
        self.state = state
        self.buffer = buffer
        self.submission = submission
        self.editorTime = editorTime
        self.sourceTime = sourceTime
    }
}

nonisolated private struct StudioExportFrameSlot {
    let index: Int
    let editorTime: TimeInterval
    let sourceTime: TimeInterval
    let visual: StudioExportVisualFrame
}

/// Serializes finishWriting and cancelWriting AFTER both media pumps exit.
/// The continuation is owned by this queue and is resumed exactly once.
nonisolated private final class StudioExportWriterFinisher: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let control: StudioExportControl
    private let queue = DispatchQueue(label: "com.screendrop.studio.export.finish")
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancellation: UUID?

    init(writer: AVAssetWriter, control: StudioExportControl) {
        self.writer = writer
        self.control = control
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                self.continuation = continuation
                self.cancellation = self.control.onFailure { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.cancel() }
                }
                if self.control.failure != nil { self.cancel(); return }
                guard self.writer.status == .writing else {
                    self.resolve(.failure(RecordingStudioExporter.ExportError.writerFailed(self.writer.error)))
                    return
                }
                self.writer.finishWriting { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        if let error = self.control.failure { self.resolve(.failure(error)) }
                        else if self.writer.status == .completed { self.resolve(.success(())) }
                        else { self.resolve(.failure(RecordingStudioExporter.ExportError.writerFailed(self.writer.error))) }
                    }
                }
            }
        }
    }

    private func cancel() {
        guard continuation != nil else { return }
        if writer.status == .writing { writer.cancelWriting() }
        resolve(.failure(control.failure ?? CancellationError()))
    }

    private func resolve(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let cancellation { control.removeHandler(cancellation) }
        cancellation = nil
        continuation.resume(with: result)
    }
}

// MARK: - Camera frame feed

/// Sequential decoder for the camera movie that answers "latest camera frame
/// at screen-time t". Screen frames arrive in order, so a one-frame
/// look-ahead over the camera reader is all that's needed.
nonisolated private final class CameraFrameFeed: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let offset: TimeInterval
    private var currentFrame: CVPixelBuffer?
    private var pendingFrame: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var isFinished = false

    init?(url: URL?, offset: TimeInterval) async throws {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecordingStudioExporter.ExportError.noVideoTrack
        }

        self.reader = reader
        self.output = output
        self.offset = offset
    }

    func latestFrame(at screenTime: TimeInterval) throws -> CVPixelBuffer? {
        while !isFinished {
            if let pending = pendingFrame {
                // Promote the very first frame unconditionally: the camera
                // starts a beat after the screen (capture warmup), and holding
                // its first frame from t=0 beats the bubble popping in late.
                guard pending.time <= screenTime || currentFrame == nil else { break }
                currentFrame = pending.buffer
                pendingFrame = nil
            }
            guard let sample = output.copyNextSampleBuffer() else {
                isFinished = true
                break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds + offset
            pendingFrame = (buffer: buffer, time: time)
        }
        if reader.status == .failed || reader.status == .cancelled {
            throw reader.error ?? RecordingStudioExporter.ExportError.cancelled
        }
        return currentFrame
    }

    func cancel() {
        reader.cancelReading()
    }
}

// MARK: - Frame compositor

nonisolated private enum StudioScreenRenderBackend: String {
    case metal
    case coreGraphics

    /// Metal is the production path; `coregraphics` is a DEBUG/reference
    /// switch so the two rasterizers can be benchmarked on identical input.
    static var configured: Self {
        guard let value = ProcessInfo.processInfo.environment[
            "SCREENDROP_STUDIO_EXPORT_BACKEND"
        ]?.lowercased() else {
            return .metal
        }
        switch value {
        case "coregraphics", "core-graphics", "cg":
            return .coreGraphics
        default:
            return .metal
        }
    }
}

/// Draws one output frame: the cached backdrop, the zoom-transformed screen
/// frame clipped to the rounded card, then the Core Graphics overlay layers.
/// The screen layer can use Metal while Core Graphics remains available as a
/// reference backend for visual comparisons.
nonisolated private final class StudioFrameCompositor: @unchecked Sendable {
    private let canvasSize: CGSize
    private let videoCropRect: CGRect
    private let layout: RecordingStudioLayout
    private let viewportTimeline: ViewportTimeline
    private let pointerTimeline: PointerTimeline?
    private let showsPressEffects: Bool
    private let keystrokeTimeline: KeystrokeCaptionTimeline?
    private let keystrokePlacement: RecordingKeystrokePlacement
    private let subtitleTimeline: SubtitleTimeline?
    private let subtitleStyle: SubtitleBarStyle
    private let karaokeTimeline: KaraokeTimeline?
    private let reframe: ReframeTrack?
    private var artworkImageCache: [String: CGImage] = [:]

    private struct KeystrokeTextKey: Equatable {
        let modifiers: String
        let key: String
    }
    private struct KeystrokeTextLayout {
        let key: KeystrokeTextKey
        let line: CTLine
        let ascent: CGFloat
        let descent: CGFloat
        let width: CGFloat
    }
    private struct SubtitleTextKey: Equatable {
        let text: String
        let karaoke: KaraokeTimeline.Line?
    }
    private struct SubtitleTextLayout {
        let key: SubtitleTextKey
        let lines: [CTLine]
        let widths: [CGFloat]
        let ascent: CGFloat
        let descent: CGFloat
    }
    private let cachesText = StudioExportPipelineOptions.cachesText
    private var keystrokeTextCache: KeystrokeTextLayout?
    private var subtitleTextCache: SubtitleTextLayout?
    private let pointerScale: CGFloat
    private let colorSpace: CGColorSpace
    private let backdrop: CGImage?
    private let coreGraphicsRenderer: StudioCoreGraphicsScreenRenderer
    private let screenBackend: StudioScreenRenderBackend
    private let metalRenderer: MetalStudioScreenRenderer?
    #if DEBUG
    private let qualityHarness: StudioScreenQualityHarness?
    #endif
    private let benchmark: StudioExportBenchmark
    /// Fixed output cadence, matching `pumpVideo`'s frame clock. Since the
    /// output timeline is gapless by construction, the shutter window for
    /// motion-blur supersampling is always exactly one output frame - no
    /// need to measure elapsed time between calls.
    private let outputFrameInterval: TimeInterval

    init(
        canvasSize: CGSize,
        videoCropRect: CGRect,
        style: RecordingStudioStyle,
        viewportTimeline: ViewportTimeline,
        pointerTimeline: PointerTimeline?,
        showsPressEffects: Bool,
        keystrokeTimeline: KeystrokeCaptionTimeline?,
        keystrokePlacement: RecordingKeystrokePlacement,
        subtitleTimeline: SubtitleTimeline?,
        subtitleStyle: SubtitleBarStyle = SubtitleBarStyle(),
        karaokeTimeline: KaraokeTimeline? = nil,
        includeBubble: Bool,
        outputFrameInterval: TimeInterval = 1.0 / 60.0,
        benchmark: StudioExportBenchmark,
        reframe: ReframeTrack? = nil,
        fitContentAspect: CGFloat? = nil
    ) {
        self.canvasSize = canvasSize
        self.videoCropRect = RecordingVideoCropGeometry.normalized(videoCropRect)
        self.layout = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: style,
            includeBubble: includeBubble,
            contentAspect: reframe?.sourceAspect ?? fitContentAspect,
            contentMode: fitContentAspect != nil && reframe == nil ? .fit : .fill,
            contentCropRect: videoCropRect
        )
        self.viewportTimeline = viewportTimeline
        self.pointerTimeline = pointerTimeline
        self.showsPressEffects = showsPressEffects
        self.keystrokeTimeline = keystrokeTimeline
        self.keystrokePlacement = keystrokePlacement
        self.subtitleTimeline = subtitleTimeline
        self.subtitleStyle = subtitleStyle
        self.karaokeTimeline = karaokeTimeline
        self.reframe = reframe
        self.outputFrameInterval = outputFrameInterval
        self.benchmark = benchmark
        self.pointerScale = style.cursorScale
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let renderedBackdrop = Self.renderBackdrop(
            canvasSize: canvasSize,
            layout: layout,
            style: style,
            colorSpace: colorSpace
        )
        self.backdrop = renderedBackdrop
        let coreGraphicsRenderer = StudioCoreGraphicsScreenRenderer(
            canvasSize: canvasSize,
            cardRect: layout.cardRect,
            cardCornerRadius: layout.cardCornerRadius,
            colorSpace: colorSpace,
            backdrop: renderedBackdrop
        )
        self.coreGraphicsRenderer = coreGraphicsRenderer

        #if DEBUG
        let qualityHarness = StudioScreenQualityHarness.configured(
            canvasSize: canvasSize,
            cardRect: layout.cardRect
        )
        self.qualityHarness = qualityHarness
        #endif

        let requestedBackend = StudioScreenRenderBackend.configured
        var metalRenderer: MetalStudioScreenRenderer?
        #if DEBUG
        let needsMetalRenderer = requestedBackend == .metal || qualityHarness != nil
        #else
        let needsMetalRenderer = requestedBackend == .metal
        #endif
        if needsMetalRenderer {
            do {
                metalRenderer = try MetalStudioScreenRenderer(
                    canvasSize: canvasSize,
                    cardRect: layout.cardRect,
                    cardCornerRadius: layout.cardCornerRadius,
                    backdrop: renderedBackdrop
                )
            } catch {
                metalRenderer = nil
                #if DEBUG
                print("[Screendrop Export Benchmark] Metal unavailable; using Core Graphics reference: \(error)")
                #endif
            }
        }
        self.metalRenderer = metalRenderer
        self.screenBackend = requestedBackend == .metal && metalRenderer == nil
            ? .coreGraphics
            : requestedBackend
        benchmark.setBackend(self.screenBackend.rawValue)
        benchmark.setFilter(self.screenBackend == .metal ? metalRenderer?.filter.rawValue ?? "none" : "none")
        benchmark.setAccumulation(self.screenBackend == .metal ? metalRenderer?.accumulation.rawValue ?? "none" : "none")
    }

    /// The virtual camera for a frame: the reframe crop-and-follow track
    /// when exporting into a different aspect, the zoom viewport otherwise.
    private func viewportFrame(at editorTime: TimeInterval) -> ViewportFrame {
        let base = reframe?.frame(at: editorTime) ?? viewportTimeline.frame(at: editorTime)
        return RecordingVideoCropGeometry.viewport(base, crop: videoCropRect)
    }

    /// Complete, conservative visual identity for reusing a finished frame.
    /// Source/camera buffers are retained, not just their object identifiers,
    /// so decoder-pool address reuse cannot produce a false cache hit.
    struct VisualState: Equatable {
        let screenFrame: CVPixelBuffer
        let cameraFrame: CVPixelBuffer?
        let viewport: ViewportFrame
        let sampleRects: [CGRect]
        let pointer: PointerFrame?
        let keystroke: KeystrokeCaptionFrame?
        let subtitle: String?
        let karaoke: KaraokeTimeline.Line?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.screenFrame === rhs.screenFrame
                && lhs.cameraFrame === rhs.cameraFrame
                && lhs.viewport == rhs.viewport
                && lhs.sampleRects == rhs.sampleRects
                && lhs.pointer == rhs.pointer
                && lhs.keystroke == rhs.keystroke
                && lhs.subtitle == rhs.subtitle
                && lhs.karaoke == rhs.karaoke
        }
    }

    var permitsFrameReuse: Bool {
        #if DEBUG
        // The reference harness must capture every frame it requested.
        if qualityHarness != nil { return false }
        #endif
        return StudioExportPipelineOptions.reusesIdenticalFrames
    }

    func visualState(
        screenFrame: CVPixelBuffer,
        cameraFrame: CVPixelBuffer?,
        editorTime: TimeInterval,
        sourceTime: TimeInterval
    ) -> VisualState {
        let shutter = outputFrameInterval
        let sampleCount = blurSampleCount(at: editorTime, shutter: shutter)
        benchmark.recordFrame(blurSampleCount: sampleCount)
        let sampleRects = (0..<sampleCount).map { sample in
            let sampleTime = editorTime - shutter / 2
                + shutter * (Double(sample) + 0.5) / Double(sampleCount)
            return layout.frameRect(for: viewportFrame(at: sampleTime))
        }
        let subtitle = subtitleTimeline?.text(at: sourceTime)
        return VisualState(
            screenFrame: screenFrame,
            cameraFrame: cameraFrame,
            viewport: viewportFrame(at: editorTime),
            sampleRects: sampleRects,
            pointer: pointerTimeline?.frame(at: editorTime),
            keystroke: keystrokeTimeline?.frame(at: sourceTime),
            subtitle: subtitle,
            karaoke: subtitle != nil && subtitleStyle.highlightsSpokenWord
                ? karaokeTimeline?.line(at: sourceTime) : nil
        )
    }

    /// Does not touch the destination with the CPU after GPU submission.
    func prepareScreen(
        frameIndex: Int,
        state: VisualState,
        editorTime: TimeInterval,
        sourceTime: TimeInterval,
        into destination: CVPixelBuffer
    ) throws -> MetalStudioScreenRenderer.Submission? {
        #if DEBUG
        if let qualityHarness,
           qualityHarness.shouldCapture(frameIndex: frameIndex, sampleCount: state.sampleRects.count) {
            try qualityHarness.capture(
                frameIndex: frameIndex,
                editorTime: editorTime,
                sourceTime: sourceTime,
                sampleCount: state.sampleRects.count,
                screenFrame: state.screenFrame,
                destination: destination,
                sampleRects: state.sampleRects,
                coreGraphicsRenderer: coreGraphicsRenderer,
                metalRenderer: metalRenderer
            )
        }
        #endif
        if screenBackend == .metal, let metalRenderer {
            return try metalRenderer.submit(
                screenFrame: state.screenFrame,
                destination: destination,
                sampleRects: state.sampleRects
            )
        }
        guard coreGraphicsRenderer.render(
            screenFrame: state.screenFrame,
            destination: destination,
            sampleRects: state.sampleRects
        ) else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }
        return nil
    }

    /// The overlay implementation and its layer order remain unchanged.
    /// Call only after the frame's GPU submission has completed.
    func finishOverlays(
        cameraFrame: CVPixelBuffer?,
        editorTime: TimeInterval,
        sourceTime: TimeInterval,
        into destination: CVPixelBuffer
    ) throws {
        guard withDestinationContext(destination, body: { context in
            drawOverlays(cameraFrame: cameraFrame, editorTime: editorTime,
                         sourceTime: sourceTime, in: context)
        }) else {
            throw RecordingStudioExporter.ExportError.writerFailed(nil)
        }
    }

    private func withDestinationContext(
        _ destination: CVPixelBuffer,
        body: (CGContext) -> Void
    ) -> Bool {
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let base = CVPixelBufferGetBaseAddress(destination),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(destination),
                height: CVPixelBufferGetHeight(destination),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
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

    private func drawOverlays(
        cameraFrame: CVPixelBuffer?,
        editorTime: TimeInterval,
        sourceTime: TimeInterval,
        in context: CGContext
    ) {
        // Pointer motion is resolved independently from viewport shutter blur.
        // Its interaction magnification and tilt stay anchored at the
        // recorded artwork anchor point, while the final point still passes
        // through the same viewport transform and rounded-card clip as the
        // source pixels.
        drawPointer(editorTime: editorTime, in: context)

        // The keystroke caption stays in card space - pinned to its edge and
        // unaffected by the zoom transform, like a broadcast lower third.
        drawKeystrokeCaption(at: sourceTime, in: context)

        if let cameraFrame,
           layout.bubbleRect.width > 0,
           let cameraImage = Self.makeImage(from: cameraFrame, colorSpace: colorSpace) {
            let bubble = layout.bubbleRect
            let imageSize = CGSize(width: cameraImage.width, height: cameraImage.height)
            let scale = max(bubble.width / imageSize.width, bubble.height / imageSize.height)
            let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let fillRect = CGRect(
                x: bubble.midX - fillSize.width / 2,
                y: bubble.midY - fillSize.height / 2,
                width: fillSize.width,
                height: fillSize.height
            )

            // Shadow + hairline border match the live preview's bubble
            // styling; the bubble sits over moving video, so both must be
            // drawn per frame rather than baked into the backdrop.
            let minDimension = min(canvasSize.width, canvasSize.height)
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -minDimension * 0.009),
                blur: minDimension * 0.022,
                color: CGColor(gray: 0, alpha: 0.35)
            )
            context.addPath(roundedPath(for: bubble, radius: layout.bubbleCornerRadius))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()

            context.saveGState()
            context.addPath(roundedPath(for: bubble, radius: layout.bubbleCornerRadius))
            context.clip()
            context.draw(cameraImage, in: flipped(fillRect))
            context.restoreGState()

            context.saveGState()
            context.addPath(roundedPath(for: bubble.insetBy(dx: 0.5, dy: 0.5), radius: layout.bubbleCornerRadius))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
            context.setLineWidth(max(1, minDimension * 0.0018))
            context.strokePath()
            context.restoreGState()
        }

        // The subtitle bar lives in canvas space - over the background too,
        // not just the card - and above everything else, camera included.
        drawSubtitleBar(at: sourceTime, in: context)
    }

    /// How many shutter sub-samples this frame needs: one when the camera is
    /// still, up to twenty-four when it sweeps, spaced so consecutive samples
    /// land roughly two output pixels apart.
    private func blurSampleCount(at editorTime: TimeInterval, shutter: TimeInterval) -> Int {
        let a = layout.frameRect(for: viewportFrame(at: editorTime - shutter / 2))
        let b = layout.frameRect(for: viewportFrame(at: editorTime + shutter / 2))
        let displacement = max(
            max(abs(a.minX - b.minX), abs(a.minY - b.minY)),
            max(abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
        )
        guard displacement > 1.5 else { return 1 }
        return min(24, max(2, Int((displacement / 2).rounded(.up))))
    }

    private func drawPointer(editorTime: TimeInterval, in context: CGContext) {
        guard let pointerTimeline,
              let pointer = pointerTimeline.frame(at: editorTime) else {
            return
        }

        let drawRect = layout.frameRect(for: viewportFrame(at: editorTime))
        let tip = CGPoint(
            x: drawRect.minX + pointer.location.x * drawRect.width,
            y: canvasSize.height - (drawRect.minY + pointer.location.y * drawRect.height)
        )

        context.saveGState()
        context.addPath(roundedPath(for: layout.cardRect, radius: layout.cardCornerRadius))
        context.clip()
        if showsPressEffects, let press = pointer.press {
            let pressTip = CGPoint(
                x: drawRect.minX + press.location.x * drawRect.width,
                y: canvasSize.height - (drawRect.minY + press.location.y * drawRect.height)
            )
            let effect = PointerPressEffectStyle.geometry(
                progress: press.progress,
                referenceHeight: layout.contentFillSize.height,
                cursorScale: pointerScale
            )
            let accent = PointerPressEffectStyle.color
            context.saveGState()
            context.setFillColor(CGColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: effect.impactOpacity
            ))
            context.fillEllipse(in: CGRect(
                x: pressTip.x - effect.impactRadius,
                y: pressTip.y - effect.impactRadius,
                width: effect.impactRadius * 2,
                height: effect.impactRadius * 2
            ))
            context.setStrokeColor(CGColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: effect.rippleOpacity
            ))
            context.setLineWidth(effect.rippleLineWidth)
            context.strokeEllipse(in: CGRect(
                x: pressTip.x - effect.rippleRadius,
                y: pressTip.y - effect.rippleRadius,
                width: effect.rippleRadius * 2,
                height: effect.rippleRadius * 2
            ))
            context.restoreGState()
        }

        if let resolved = artwork(for: pointer, in: pointerTimeline) {
            let height = layout.contentFillSize.height
                * PointerArtworkMetrics.heightRatio
                * pointerScale
                * resolved.intrinsicScale
            let size = CGSize(width: height * resolved.aspectRatio, height: height)
            context.setAlpha(CGFloat(min(max(pointer.opacity, 0), 1)))
            context.translateBy(x: tip.x, y: tip.y)
            context.rotate(by: -CGFloat(pointer.tiltDegrees * .pi / 180))
            let interactionScale = CGFloat(max(pointer.magnification, 0.1))
            context.scaleBy(x: interactionScale, y: interactionScale)
            context.draw(
                resolved.image,
                in: CGRect(
                    x: -resolved.anchor.x * size.width,
                    y: -(1 - resolved.anchor.y) * size.height,
                    width: size.width,
                    height: size.height
                )
            )
        }
        context.restoreGState()
    }

    private func drawKeystrokeCaption(at time: TimeInterval, in context: CGContext) {
        guard let keystrokeTimeline,
              let caption = keystrokeTimeline.frame(at: time) else {
            return
        }

        let metrics = KeystrokeCaptionMetrics(cardHeight: layout.cardRect.height)
        let (modifierText, keyText) = KeystrokeCaptionMetrics.text(for: caption)
        let key = KeystrokeTextKey(modifiers: modifierText, key: keyText)
        let textLayout: KeystrokeTextLayout
        if cachesText, let cached = keystrokeTextCache, cached.key == key {
            textLayout = cached
        } else {
            let font = Self.captionFont(size: metrics.fontSize)

            let text = NSMutableAttributedString()
            if !modifierText.isEmpty {
                text.append(NSAttributedString(string: modifierText, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        CGColor(gray: 1, alpha: KeystrokeCaptionMetrics.modifierAlpha)
                ]))
            }
            text.append(NSAttributedString(string: keyText, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 1, alpha: 1)
            ]))

            let line = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            textLayout = KeystrokeTextLayout(key: key, line: line, ascent: ascent, descent: descent, width: textWidth)
            if cachesText { keystrokeTextCache = textLayout }
        }
        let line = textLayout.line
        let ascent = textLayout.ascent
        let descent = textLayout.descent
        let textWidth = textLayout.width
        guard textWidth > 0 else { return }

        let pillSize = CGSize(
            width: textWidth + metrics.paddingHorizontal * 2,
            height: ascent + descent + metrics.paddingVertical * 2
        )
        let origin = metrics.pillOrigin(
            pillSize: pillSize,
            cardRect: layout.cardRect,
            placement: keystrokePlacement
        )
        let pillRect = flipped(CGRect(origin: origin, size: pillSize))

        context.saveGState()
        context.setAlpha(CGFloat(caption.opacity))
        context.translateBy(x: pillRect.midX, y: pillRect.midY)
        context.scaleBy(x: CGFloat(caption.scale), y: CGFloat(caption.scale))
        context.translateBy(x: -pillRect.midX, y: -pillRect.midY)

        let radius = min(metrics.cornerRadius, pillRect.height / 2)
        context.addPath(CGPath(
            roundedRect: pillRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(CGColor(gray: 0, alpha: KeystrokeCaptionMetrics.backgroundAlpha))
        context.fillPath()

        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: pillRect.minX + metrics.paddingHorizontal,
            y: pillRect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawSubtitleBar(at time: TimeInterval, in context: CGContext) {
        guard let subtitleTimeline,
              let text = subtitleTimeline.text(at: time) else {
            return
        }

        let metrics = SubtitleBarMetrics(canvasSize: canvasSize, style: subtitleStyle)
        let maximumTextWidth = metrics.maximumTextWidth(canvasWidth: canvasSize.width)

        let key = SubtitleTextKey(
            text: text,
            karaoke: subtitleStyle.highlightsSpokenWord ? karaokeTimeline?.line(at: time) : nil
        )
        let textLayout: SubtitleTextLayout
        if cachesText, let cached = subtitleTextCache, cached.key == key {
            textLayout = cached
        } else {
            // On narrow canvases the text wraps into centered lines rather
            // than shrinking into a full-width sliver; the font only scales
            // down when even the maximum line count can't hold it.
            var fontSize = metrics.fontSize
            var wrappedLines: [CTLine] = []
            for _ in 0..<3 {
                let font = Self.captionFont(size: fontSize)
                let attributed = subtitleAttributedText(plainText: text, at: time, font: font)
                wrappedLines = Self.wrapLines(attributed, width: maximumTextWidth)
                if wrappedLines.count <= SubtitleBarMetrics.maximumLineCount || fontSize <= 11 {
                    break
                }
                fontSize *= CGFloat(SubtitleBarMetrics.maximumLineCount) / CGFloat(wrappedLines.count)
            }
            guard !wrappedLines.isEmpty else { return }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidths = wrappedLines.map {
                CGFloat(CTLineGetTypographicBounds($0, &ascent, &descent, &leading))
            }
            textLayout = SubtitleTextLayout(key: key, lines: wrappedLines, widths: lineWidths, ascent: ascent, descent: descent)
            if cachesText { subtitleTextCache = textLayout }
        }
        let wrappedLines = textLayout.lines
        let lineWidths = textLayout.widths
        let ascent = textLayout.ascent
        let descent = textLayout.descent
        guard let widestLine = lineWidths.max(), widestLine > 0 else { return }
        let lineAdvance = (ascent + descent) * SubtitleBarMetrics.lineSpacingFactor
        let textHeight = ascent + descent + lineAdvance * CGFloat(wrappedLines.count - 1)

        let barSize = CGSize(
            width: widestLine + metrics.paddingHorizontal * 2,
            height: textHeight + metrics.paddingVertical * 2
        )
        let barCenterY = canvasSize.height * CGFloat(subtitleStyle.clampedVerticalPosition)
        let origin = CGPoint(
            x: canvasSize.width / 2 - barSize.width / 2,
            y: barCenterY - barSize.height / 2
        )
        let barRect = flipped(CGRect(origin: origin, size: barSize))

        context.saveGState()
        let radius = min(metrics.cornerRadius, barRect.height / 2)
        context.addPath(CGPath(
            roundedRect: barRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(CGColor(gray: 0, alpha: SubtitleBarMetrics.backgroundAlpha))
        context.fillPath()

        context.textMatrix = .identity
        // The CG context is bottom-up, so the first wrapped line sits at
        // the top of the bar and subsequent lines step downward.
        let firstBaseline = barRect.maxY - metrics.paddingVertical - ascent
        for (index, wrappedLine) in wrappedLines.enumerated() {
            context.textPosition = CGPoint(
                x: barRect.midX - lineWidths[index] / 2,
                y: firstBaseline - lineAdvance * CGFloat(index)
            )
            CTLineDraw(wrappedLine, context)
        }
        context.restoreGState()
    }

    /// Word-wraps an attributed string into CTLines within a width.
    private static func wrapLines(
        _ attributed: NSAttributedString,
        width: CGFloat
    ) -> [CTLine] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: max(24, width), height: 100_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        return (CTFrameGetLines(frame) as? [CTLine]) ?? []
    }

    /// The bar's text: karaoke-colored words when word timings exist and
    /// the style asks for them, the plain cue text otherwise. Colors match
    /// StudioSubtitleBarView exactly.
    private func subtitleAttributedText(
        plainText: String,
        at time: TimeInterval,
        font: CTFont
    ) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        guard subtitleStyle.highlightsSpokenWord,
              let karaokeTimeline,
              let karaokeLine = karaokeTimeline.line(at: time),
              !karaokeLine.words.isEmpty else {
            return NSAttributedString(string: plainText, attributes: [
                fontKey: font,
                colorKey: CGColor(gray: 1, alpha: 1)
            ])
        }

        let text = NSMutableAttributedString()
        for (index, word) in karaokeLine.words.enumerated() {
            let color: CGColor
            if index == karaokeLine.activeIndex {
                color = SubtitleBarMetrics.karaokeAccent
            } else if index < karaokeLine.spokenCount {
                color = CGColor(gray: 1, alpha: 1)
            } else {
                color = CGColor(gray: 1, alpha: SubtitleBarMetrics.karaokeUpcomingAlpha)
            }
            text.append(NSAttributedString(
                string: index > 0 ? " \(word)" : word,
                attributes: [fontKey: font, colorKey: color]
            ))
        }
        return text
    }

    private static func captionFont(size: CGFloat) -> CTFont {
        let descriptor = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        let rounded = descriptor.withDesign(.rounded) ?? descriptor
        return CTFontCreateWithFontDescriptor(rounded as CTFontDescriptor, size, nil)
    }

    private func artwork(
        for pointer: PointerFrame,
        in timeline: PointerTimeline
    ) -> (image: CGImage, anchor: CGPoint, aspectRatio: CGFloat, intrinsicScale: CGFloat)? {
        if let resolved = timeline.artwork(id: pointer.artworkID),
           let image = artworkImage(for: resolved) {
            return (
                image,
                resolved.normalizedAnchor,
                resolved.aspectRatio,
                resolved.intrinsicScale
            )
        }
        return nil
    }

    private func artworkImage(for artwork: PointerArtwork) -> CGImage? {
        if let cached = artworkImageCache[artwork.artworkID] {
            return cached
        }
        guard let source = CGImageSourceCreateWithData(artwork.imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        artworkImageCache[artwork.artworkID] = image
        return image
    }

    /// Layout rects use a top-left origin; CoreGraphics draws bottom-up.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: canvasSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func roundedPath(for rect: CGRect, radius: CGFloat) -> CGPath {
        let flippedRect = flipped(rect)
        let boundedRadius = min(radius, min(flippedRect.width, flippedRect.height) / 2)
        guard boundedRadius > 0.5 else { return CGPath(rect: flippedRect, transform: nil) }
        return CGPath(
            roundedRect: flippedRect,
            cornerWidth: boundedRadius,
            cornerHeight: boundedRadius,
            transform: nil
        )
    }

    private static func makeImage(from pixelBuffer: CVPixelBuffer, colorSpace: CGColorSpace) -> CGImage? {
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
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        return context.makeImage()
    }

    private static func renderBackdrop(
        canvasSize: CGSize,
        layout: RecordingStudioLayout,
        style: RecordingStudioStyle,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        switch style.background {
        case .none:
            context.setFillColor(CGColor(gray: 0.04, alpha: 1))
            context.fill(canvasRect)
        case .solid(let color):
            context.setFillColor(CGColor(
                colorSpace: colorSpace,
                components: [color.red, color.green, color.blue, color.alpha]
            ) ?? CGColor(gray: 0, alpha: 1))
            context.fill(canvasRect)
        case .gradient(let gradient):
            let cgColors = gradient.colors.map { color in
                CGColor(
                    colorSpace: colorSpace,
                    components: [color.red, color.green, color.blue, color.alpha]
                ) ?? CGColor(gray: 0, alpha: 1)
            }
            if let cgGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: cgColors as CFArray,
                locations: nil
            ) {
                // UnitPoint has a top-left origin; the context is bottom-up.
                let start = CGPoint(
                    x: gradient.startPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.startPoint.y * canvasSize.height
                )
                let end = CGPoint(
                    x: gradient.endPoint.x * canvasSize.width,
                    y: canvasSize.height - gradient.endPoint.y * canvasSize.height
                )
                context.drawLinearGradient(cgGradient, start: start, end: end, options: [
                    .drawsBeforeStartLocation,
                    .drawsAfterEndLocation
                ])
            }
        case .customWallpaper(let wallpaper):
            if let source = CGImageSourceCreateWithURL(wallpaper.url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [
                   kCGImageSourceShouldCache: false
               ] as CFDictionary) {
                let imageSize = CGSize(width: image.width, height: image.height)
                let scale = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
                let fillSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let fillRect = CGRect(
                    x: (canvasSize.width - fillSize.width) / 2,
                    y: (canvasSize.height - fillSize.height) / 2,
                    width: fillSize.width,
                    height: fillSize.height
                )
                context.draw(image, in: fillRect)
            } else {
                context.setFillColor(CGColor(gray: 0.04, alpha: 1))
                context.fill(canvasRect)
            }
        }

        // Card shadow: static, so it lives in the backdrop. The filled shape
        // is fully covered by video pixels every frame.
        if style.shadow > 0.01, style.background != .none {
            let minDimension = min(canvasSize.width, canvasSize.height)
            let blur = minDimension * 0.045 * style.shadow
            let cardRect = CGRect(
                x: layout.cardRect.minX,
                y: canvasSize.height - layout.cardRect.maxY,
                width: layout.cardRect.width,
                height: layout.cardRect.height
            )
            let radius = min(layout.cardCornerRadius, min(cardRect.width, cardRect.height) / 2)
            let path = radius > 0.5
                ? CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: cardRect, transform: nil)

            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -blur * 0.35),
                blur: blur,
                color: CGColor(gray: 0, alpha: 0.55 * style.shadow)
            )
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        return context.makeImage()
    }
}
