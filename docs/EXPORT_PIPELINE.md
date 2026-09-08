# Studio export pipeline: pass2 implementation

## Scope and provenance

The delivery integrates the candidate that was tested in GitHub Actions run
34152606749 as ordinary source files. Previously the review branch held the
candidate as encoded patches that CI applied only inside its temporary working
tree. Merely checking out that review branch did not enable the new exporter.

Base: `perf/metal-studio-export-pass1`, commit
`2e891f6ac625fe10c48d8e0f03506dc575e879b3`.
Verified source tree: `13e9d3c93ef5b920c3d7aa7b3d3363dc2e1072aa`.

The five export implementation/probe Swift files are byte-identical to the
successful native run's tested source archive. No performance improvement in
pass1 is attributed to this delivery. The independent perspective-shadow fix
from main commit `516a53227bac614f58fa2516b7208e43a6cb7f94` is also carried forward;
its two Swift files match main's Git blob hashes exactly. It is not a new export
optimization. The combined source package has not been newly built on macOS.

## Execution model

An export freezes its configuration. A dedicated video worker selects source
samples and prepares up to three ordered frame slots. Screen/zoom/motion-blur
commands are submitted to the existing tracked Metal command queue. The worker
waits for the oldest required GPU result, draws the existing Core Graphics
foreground overlays, and submits that completed buffer to AVAssetWriter.

Audio has a separate worker and retains existing composition/mix/replacement
behavior. The worker discovers end-of-stream before waiting for writer readiness,
so an exhausted audio input does not unnecessarily hold up interleaving. Both
workers must finish before writer finalization. No source or output frames are
dropped to increase export speed.

Source-frame acquisition can overlap previously submitted GPU work. Encoding can
consume earlier completed frames while later frames are prepared. This is not an
unbounded concurrent render farm or a fully GPU-only compositor. Camera and text
overlays intentionally retain their prior Core Graphics drawing implementation.

## Ownership and synchronization invariants

1. Each reader output has one consuming worker. Each writer input has one appending
   worker. Cross-worker reader cancellation and writer status observation are
   explicitly scoped exceptions, not permission for arbitrary concurrent access.
2. Each asynchronous GPU submission retains both CVMetalTexture wrappers and the
   associated source/destination pixel buffers until the GPU completion callback.
   Cancellation cannot recycle a buffer still used by the GPU.
3. Core Graphics never draws into an unfinished Metal output. Writer submission
   occurs after all screen and foreground work completes.
4. Submitted output storage is never edited again. AVFoundation retains what it
   needs, and the pixel-buffer pool is responsible for safe recycling.
5. Shared accumulation textures use the existing tracked Metal queue. Do not
   replace it with MTL4CommandQueue without explicit hazard synchronization.
6. First failure wins. Cancellation/error callbacks run outside the control lock.
   Sibling workers are awakened before error propagation waits for them.
7. Writer finish/cancel and completion continuation resolution are serialized.
   Failure removes the temporary output instead of returning it as a valid movie.

## Bounded work, not a total memory guarantee

`SCREENDROP_STUDIO_EXPORT_DEPTH` defaults to 3 and is clamped to 1..3. This bounds
application-held pending frame slots. It does not cap the entire process, the
encoder's internal queues, driver allocations, decoded reference frames, or all
pixel-buffer-pool allocations. Existing timeline metadata and pointer artwork can
also scale with the project. Do not advertise a fixed total memory ceiling.

The exporter does not allocate a frame array proportional to video duration.
Decoded samples are held using current/lookahead references, and the Core Text
layout caches retain only the latest needed layout. Output buffer allocation is
still AVFoundation-managed. A pool minimum count is not an allocation limit.

## Safe work avoidance

The clip index retains the original left-to-right floating-point prefix sums and
uses binary search. It preserves segment-boundary and source-time behavior, rather
than replacing it with a mathematically similar schedule that selects different
frames at a boundary.

Consecutive output frames may share completed pixels only when retained source
and camera buffer identity and all evaluated visual state match: viewport,
motion-blur sample rectangles, cursor, keystrokes, subtitle content and spoken-word
highlight state. Retaining the buffers prevents allocation-address reuse from
being mistaken for source equality. Every output timestamp is still appended.
The optimization is conservative, not pixel-based change detection or a change
to the requested frame rate.

The subtitle and keystroke caches reuse Core Text layout objects. They do not
rasterize the entire transcript in advance, replace fonts, reduce resolution,
move text onto approximate glyph atlases, or change fractional-pixel placement.

## Deliberately unchanged

Mitchell filtering, FP16 accumulation, shader math, blur sample policy, screen and
camera positioning, rounded clipping, overlay ordering, subtitle/karaoke drawing,
H.264/HEVC settings, bitrates, audio format, container choices and fast-start policy
remain the same as pass1. Core Graphics remains the reference/fallback backend.

The original 60fps schedule and `CMTime(seconds:..., preferredTimescale:600)` are
preserved, including that conversion's existing rounding. The implementation does
not silently replace it with integer-frame time arithmetic. A future timing
correction would be a separately reviewed behavioral change.

## Measurements

DEBUG diagnostics distinguish source decode, frame preparation, GPU submission,
GPU execution, GPU wait, foreground CPU work, writer readiness wait, append and
finalization. These intervals can overlap and are not all additive. Run with pixel
hashing disabled for throughput measurements. Report complete export wall time,
actual hardware, build configuration, resolution and enabled features.

The native reference run used an Apple Paravirtual device in a macOS VM. Its
30-second static 1080p60 workload had medians of 9.304692s (pass1) and 9.185297s
(candidate), about 1.3% speedup. It avoided 1,799 of 1,800 renders, but the writer
still dominated. This is not a claimed gain on the user's physical Mac or on
long dynamic camera footage.

Short feature fixtures with pixel hashing enabled had larger timing differences.
Those diagnostic runs are correctness evidence, not representative production
throughput benchmarks.

## Apple sources consulted and decisions

Sources were checked on September 8, 2026. These documents support design choices,
not an Apple guarantee of a particular speedup or an endorsement of this code.

- [Synchronizing CPU and GPU work](https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work): overlap work using distinct resources and respect completion before reuse. Three slots are a conservative starting configuration, not a universal throughput optimum.
- [CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)): explicitly retain the returned Core Video texture until GPU execution finishes. Implemented via completion-scoped texture leases.
- [AVAssetWriterInput.isReadyForMoreMediaData](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/isreadyformoremediadata): writer readiness controls multi-input interleaving and is key-value observable. The wake signal observes the writer-input property, not the similarly named, non-KVO queued-renderer property.
- [Pixel buffer receiver creation](https://developer.apple.com/documentation/avfoundation/avassetwriter/inputpixelbufferreceiver(for:pixelbufferattributes:)): macOS 26 provides a modern receiver interface. Evaluated but not substituted into this already native-tested candidate merely for novelty. Its existence alone does not prove faster hardware encoding; migration needs new cancellation, buffer-ownership and finalization tests.
- [Core Video allocation threshold](https://developer.apple.com/documentation/corevideo/kcvpixelbufferpoolallocationthresholdkey): an allocation threshold differs from a minimum pool size. No unsupported total-pool-cap claim is made for this implementation.
- [Metal command buffers](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html): limit submission overhead without starving the GPU. This older guidance is used alongside current documentation, not represented as a recent API announcement.
- [Metal resource synchronization](https://developer.apple.com/documentation/metal/resource-synchronization): MTL4CommandQueue requires explicit synchronization and does not honor hazardTrackingMode as the old queue does. A casual queue-type swap would be unsafe here.

## Remaining release gates

A fresh combined-source native run; physical Apple Silicon sustained-throughput
and memory tests; one-hour or longer exports with representative real media;
audio synchronization/quality checks beyond presence and decodability; additional
failure injection for full disk, failed encoder and cancellation during finalization;
and a macOS 26.0 compatibility run if 26.0 is the contractual minimum.

No native compiler or writable CI dispatch connection was available in the final
integration session. Historical native build success is explicitly distinguished
from those still-pending gates.
