//
//  StudioExportScheduling.swift
//  Screendrop
//
//  Offline-export coordination. Blocking waits run only on the export's
//  dedicated Dispatch queues, never on Swift's cooperative executor.
//

import Foundation

/// First failure wins. Failure callbacks are copied under the lock and invoked
/// outside it, so callbacks may unregister, signal a waiter, or cancel I/O.
nonisolated final class StudioExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: (any Error)?
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    var failure: (any Error)? { lock.withLock { storedFailure } }
    var isCancelled: Bool { failure != nil }

    func check() throws {
        if let failure { throw failure }
    }

    func cancel() { fail(CancellationError()) }

    func fail(_ error: any Error) {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            guard storedFailure == nil else { return [] }
            storedFailure = error
            let callbacks = Array(handlers.values)
            handlers.removeAll()
            return callbacks
        }
        for callback in callbacks { callback() }
    }

    @discardableResult
    func onFailure(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        let callNow = lock.withLock {
            if storedFailure != nil { return true }
            handlers[token] = handler
            return false
        }
        if callNow { handler() }
        return token
    }

    func removeHandler(_ token: UUID) {
        lock.withLock { _ = handlers.removeValue(forKey: token) }
    }
}

/// A generation counter closes the check/sleep race. In particular, never
/// query AVFoundation properties while holding this condition: a KVO callback
/// may run while AVFoundation holds an internal lock.
nonisolated final class StudioExportWakeSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var generation: UInt64 = 0

    func signal() {
        condition.lock()
        generation &+= 1
        condition.broadcast()
        condition.unlock()
    }

    func waitUntil(
        healthCheckInterval: TimeInterval = 0.25,
        _ isReady: () throws -> Bool
    ) rethrows {
        while true {
            condition.lock()
            let observedGeneration = generation
            condition.unlock()

            // Framework calls and cancellation checks stay outside the lock.
            if try isReady() { return }

            condition.lock()
            if generation == observedGeneration {
                // This is a failure-health fallback, not a frame-rate timer.
                // Writer readiness and explicit cancellation wake immediately.
                _ = condition.wait(until: Date(timeIntervalSinceNow: healthCheckInterval))
            }
            condition.unlock()
        }
    }
}

/// Precomputes precisely the same left-to-right floating-point sums as
/// RecordingClipTimeline.location(at:). Queries do not rescan every clip or
/// recompute the edited duration for each of the 216,000 frames in an hour.
nonisolated struct StudioExportClipIndex: Sendable {
    private let segments: [RecordingClipSegment]
    private let starts: [TimeInterval]
    private let ends: [TimeInterval]
    let duration: TimeInterval

    init(_ timeline: RecordingClipTimeline) {
        segments = timeline.segments
        var starts: [TimeInterval] = []
        var ends: [TimeInterval] = []
        starts.reserveCapacity(segments.count)
        ends.reserveCapacity(segments.count)
        var total: TimeInterval = 0
        for segment in segments {
            starts.append(total)
            total += segment.editorDuration
            ends.append(total)
        }
        self.starts = starts
        self.ends = ends
        duration = total
    }

    func location(at editorTime: TimeInterval) -> RecordingClipTimeline.Location? {
        guard !segments.isEmpty, duration > 0, editorTime.isFinite else { return nil }
        let clamped = min(max(editorTime, 0), duration)
        var low = 0
        var high = ends.count
        while low < high {
            let middle = low + (high - low) / 2
            if clamped < ends[middle] { high = middle }
            else { low = middle + 1 }
        }
        let index = min(low, segments.count - 1)
        let segment = segments[index]
        let offset = min(max(clamped - starts[index], 0), segment.editorDuration)
        return RecordingClipTimeline.Location(
            segmentIndex: index,
            segmentID: segment.id,
            editorStart: starts[index],
            offset: offset,
            sourceTime: segment.sourceStart + min(offset * segment.speed, segment.duration)
        )
    }
}

nonisolated enum StudioExportPipelineOptions {
    /// Three slots overlap CPU preparation, GPU rasterization and encoding.
    /// Slots include pending writer submission, not just GPU-in-flight work.
    static var depth: Int {
        let raw = ProcessInfo.processInfo.environment["SCREENDROP_STUDIO_EXPORT_DEPTH"]
        return min(3, max(1, raw.flatMap(Int.init) ?? 3))
    }

    static var reusesIdenticalFrames: Bool {
        ProcessInfo.processInfo.environment["SCREENDROP_STUDIO_EXPORT_REUSE"] != "0"
    }

    static var cachesText: Bool {
        ProcessInfo.processInfo.environment["SCREENDROP_STUDIO_EXPORT_TEXT_CACHE"] != "0"
    }
}
