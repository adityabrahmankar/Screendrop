    // Test-only extension injected into an isolated build, never the shipping app.
    private static func prepareLong(_ root: URL, seconds: Double) async throws {
        try await prepare(root)
        try await movie(root.appendingPathComponent("long-static.mov"), width: 960,
                        height: 540, duration: seconds, step: seconds)
        for name in ["source", "camera"] {
            let asset = AVURLAsset(url: root.appendingPathComponent("\(name).mov"))
            let composition = AVMutableComposition()
            let sourceDuration = try await asset.load(.duration)
            let end = CMTime(seconds: seconds, preferredTimescale: 600)
            try require(sourceDuration.seconds > 0, "invalid loop fixture")
            for kind in [AVMediaType.video, AVMediaType.audio] {
                for source in try await asset.loadTracks(withMediaType: kind) {
                    guard let target = composition.addMutableTrack(withMediaType: kind,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw Failure.assertion("loop fixture track")
                    }
                    var at = CMTime.zero
                    while at < end {
                        let remaining = end - at
                        let length = remaining < sourceDuration ? remaining : sourceDuration
                        try target.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
                        at = at + length
                    }
                }
            }
            guard let exporter = AVAssetExportSession(asset: composition,
                presetName: AVAssetExportPresetPassthrough) else {
                throw Failure.assertion("loop fixture muxer")
            }
            try await exporter.export(to: root.appendingPathComponent("long-\(name).mov"), as: .mov)
        }
    }

    private static func longConfiguration(_ root: URL, seconds: Double, effects: Bool) -> RecordingStudioExporter.Configuration {
        let template = configuration(root, mode: effects ? "all" : "benchmark")
        let clips = RecordingClipTimeline(segments: [RecordingClipSegment(sourceStart: 0, sourceEnd: seconds)])
        var capture = PointerCaptureFile()
        if effects {
            capture.travel = (0...Int(seconds * 4)).map { i in
                PointerTravelSample(time: Double(i) / 4, x: 0.15 + Double(i % 5) * 0.16,
                                    y: 0.2 + Double(i % 3) * 0.24)
            }
            if let image = try? Data(contentsOf: root.appendingPathComponent("pointer.png")) {
                capture.artwork = [PointerArtwork(artworkID: "fixture-arrow", imageData: image,
                    anchorPoint: .init(x: 1, y: 1), referenceSize: .init(width: 24, height: 24))]
                for i in capture.travel.indices { capture.travel[i].artworkID = "fixture-arrow" }
            }
        }
        var cues: [ZoomCue] = []
        var subtitles: [RecordingSubtitleCue] = []
        var words: [RecordingTranscriptWord] = []
        if effects {
            for base in stride(from: 0.0, to: seconds, by: 4.0) {
                if base + 1.8 > seconds { break }
                capture.presses.append(PointerPressEvent(time: base + 0.6, x: 0.3, y: 0.45, button: 0, phase: .down))
                capture.presses.append(PointerPressEvent(time: base + 0.73, x: 0.3, y: 0.45, button: 0, phase: .up))
                capture.keystrokes.append(RecordingKeystrokeEvent(time: base + 0.35, modifiers: ["⌘", "⇧"], key: "K"))
                cues.append(ZoomCue(start: base + 0.4, end: base + 1.8, zoom: 1.8,
                                    anchorMode: .pinnedAnchor, pinnedPoint: CGPoint(x: 0.7, y: 0.32)))
                subtitles.append(RecordingSubtitleCue(start: base + 0.3, end: base + 1.8,
                                                       text: "Long export stays synchronized."))
                for (i, text) in ["Long ", "export ", "stays ", "synchronized."].enumerated() {
                    words.append(RecordingTranscriptWord(text: text, start: base + 0.3 + Double(i) * 0.35,
                                                          end: base + 0.65 + Double(i) * 0.35))
                }
            }
        }
        let viewport = effects ? ViewportTimeline.build(cues: cues, capture: capture, clipTimeline: clips) : .identity
        let pointer = effects ? PointerTimeline.build(capture: capture, duration: seconds,
            recordingSizeInPoints: CGSize(width: 960, height: 540), clipTimeline: clips) : nil
        return RecordingStudioExporter.Configuration(
            screenURL: root.appendingPathComponent(effects ? "long-source.mov" : "long-static.mov"),
            cameraURL: effects ? root.appendingPathComponent("long-camera.mov") : nil,
            cameraOffset: template.cameraOffset, style: template.style,
            viewportTimeline: viewport, pointerTimeline: pointer, showsPressEffects: effects,
            keystrokeTimeline: effects ? KeystrokeCaptionTimeline(events: capture.keystrokes) : nil,
            keystrokePlacement: template.keystrokePlacement,
            subtitleTimeline: effects ? SubtitleTimeline(cues: subtitles) : nil,
            subtitleStyle: template.subtitleStyle,
            karaokeTimeline: effects ? KaraokeTimeline(cues: subtitles, words: words) : nil,
            canvasSize: CGSize(width: 1920, height: 1080),
            videoCropRect: template.videoCropRect, clipTimeline: clips, exportSettings: template.exportSettings)
    }
