# Studio export goal and TODO

Goal: export the same edited recording faster on macOS 26+, with bounded application-owned frame resources. Preserve the pass1 Mitchell filter, FP16 accumulation, motion-blur sample policy, frame schedule, overlay drawing order, codecs, quality settings, audio and UI export entry point.

- [x] Audit pass1 and recover the staged review candidate independently of earlier conversational claims.
- [x] Implement ordered three-slot GPU submission, retained texture leases, writer backpressure, clip indexing and single-entry text-layout caches.
- [x] Harden sibling failure propagation, cancellation, finalization and temporary-output cleanup.
- [x] Add size-aware queue depth, bounded camera-read autoreleases and throttled progress updates.
- [x] Run scheduling tests: 555,684 exact mapping comparisons plus wake/cancellation, depth-budget and progress tests.
- [ ] Build and run the final candidate on macOS arm64, including raw pixel and PCM equivalence.
- [ ] Complete a real 216,000-frame, one-hour media-duration export and measure memory growth.
- [ ] Publish ordinary source commits and an evidence report on a separate performance branch.
- [ ] Physical Apple Silicon acceptance: user's real long recording, sustained 1080p/4K, visual playback and thermal profiling. CI's virtual GPU cannot establish physical M4 throughput.

Do not mark the final hardware-acceptance item complete based on a build, static analysis, virtual-GPU timing, or a low-resolution soak test.
