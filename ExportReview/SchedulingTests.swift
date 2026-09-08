import Foundation

private enum TestFailure: Error { case failed(String); case first; case second }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}
private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func read() -> T { lock.withLock { value } }
    func update(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}
private struct Generator {
    var value: UInt64 = 0x12345678abcdef
    mutating func next() -> Double {
        value = value &* 6364136223846793005 &+ 1442695040888963407
        return Double(value >> 11) / 9007199254740992.0
    }
}

@main
private enum SchedulingTests {
    static func main() throws {
        var comparisons = 0
        var random = Generator()
        for count in [0, 1, 2, 17, 200, 1000] {
            var segments: [RecordingClipSegment] = []
            var source: Double = 0
            for _ in 0..<count {
                let length = 0.12 + random.next() * 20
                segments.append(RecordingClipSegment(sourceStart: source, sourceEnd: source + length, speed: 1 + random.next() * 7))
                source += length + random.next() * 4
            }
            let timeline = RecordingClipTimeline(segments: segments)
            let index = StudioExportClipIndex(timeline)
            try require(index.duration == timeline.duration, "duration sums changed")
            var times = [-1.0, 0, index.duration, index.duration + 1]
            var boundary: Double = 0
            for segment in segments {
                boundary += segment.editorDuration
                times += [boundary.nextDown, boundary, boundary.nextUp]
            }
            times += (0..<20_000).map { _ in random.next() * max(1, index.duration) }
            for time in times {
                try require(index.location(at: time) == timeline.location(at: time), "clip mapping differs at \(time), clips=\(count)")
                comparisons += 1
            }
        }
        // Two hours of fixed output ticks with actual model code, not a mock.
        let long = RecordingClipTimeline(segments: (0..<120).map {
            RecordingClipSegment(sourceStart: Double($0 * 120), sourceEnd: Double($0 * 120 + 120), speed: 2)
        })
        let longIndex = StudioExportClipIndex(long)
        for frame in 0..<432_000 {
            let time = Double(frame) / 60
            try require(longIndex.location(at: time) == long.location(at: time), "long export mapping differs at frame \(frame)")
            comparisons += 1
        }

        let control = StudioExportControl()
        let calls = LockedValue(0)
        let removed = control.onFailure { calls.update { $0 += 1000 } }
        control.removeHandler(removed)
        control.onFailure {
            calls.update { $0 += 1 }
            // Reentrant registration must call immediately without lock deadlock.
            control.onFailure { calls.update { $0 += 10 } }
        }
        control.fail(TestFailure.first)
        control.fail(TestFailure.second)
        try require(calls.read() == 11, "failure callbacks lost or repeated")
        do { try control.check(); throw TestFailure.failed("missing failure") }
        catch TestFailure.first {} // Must preserve first error.
        let cancelled = StudioExportControl()
        cancelled.cancel()
        do { try cancelled.check(); throw TestFailure.failed("missing cancellation") }
        catch is CancellationError {}

        // Signals delivered between predicate evaluation and condition wait
        // must not be lost. No timeout wakeup is needed for this test.
        for _ in 0..<1000 {
            let signal = StudioExportWakeSignal()
            var attempts = 0
            signal.waitUntil(healthCheckInterval: 30) {
                attempts += 1
                if attempts == 1 { signal.signal(); return false }
                return true
            }
            try require(attempts == 2, "lost readiness wake")
        }
        let wake = StudioExportWakeSignal()
        let waitingControl = StudioExportControl()
        let done = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let caughtCancellation = LockedValue(false)
        waitingControl.onFailure { wake.signal() }
        DispatchQueue(label: "export.test.wait").async {
            do {
                try wake.waitUntil(healthCheckInterval: 30) {
                    entered.signal()
                    try waitingControl.check()
                    return false
                }
            } catch is CancellationError { caughtCancellation.update { $0 = true } }
            catch {}
            done.signal()
        }
        try require(entered.wait(timeout: .now() + 3) == .success, "worker failed to enter wait")
        waitingControl.cancel()
        try require(done.wait(timeout: .now() + 3) == .success, "cancellation failed to wake readiness wait")
        try require(caughtCancellation.read(), "wrong cancellation result")
        print("PASS: \(comparisons) exact clip-mapping comparisons; first-error, reentrancy, 1000 lost-wake checks and cancellation wake.")
    }
}
