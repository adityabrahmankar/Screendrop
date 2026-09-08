# Reproducible export validation

## Short native regression suite

On Apple Silicon, using Xcode 26.4 or later:

```bash
bash ExportReview/verify_macos.sh
```

This builds normal source files in Debug and Release, builds the pinned pass1
reference with only a test hook/hash probe, then compares every pre-encoder frame
for eleven Metal cases and three Core Graphics cases. It also checks output frame
count, existing presentation times, dimensions, duration, audio presence and PCM
readback, immediate/during-export cancellation and invalid input. Three static
30-second timing pairs run with pixel hashing disabled.

The pass1 commit must exist in git history. For the standalone source bundle:

```bash
SCREENDROP_BASELINE_ARCHIVE=/absolute/path/to/reference/pass1.tar.gz \
  bash ExportReview/verify_macos.sh
```

The suite generates synthetic media and does not request screen/camera capture
permissions. Existing project dependencies may be resolved by Xcode. A nonzero
exit code is a failure; consult the retained logs. Tests do not certify notarization,
recording capture UI or every real-world media combination.

## Optimized long-video test

```bash
python3 ExportReview/run_long_macos.py \
  --seconds 3600 --scenario effects --repetitions 3 \
  --results /absolute/path/to/new-long-export-results
```

Add `--baseline-archive /absolute/path/to/reference/pass1.tar.gz` without git
history. Use a new results directory. The command builds isolated Release-optimized
apps with DEBUG test hooks, loops synthetic screen/camera/audio fixtures, and
repeats zooms, cursor/press effects, keystrokes and highlighted subtitles throughout
the selected duration. The source app is never modified. `--scenario static` is
also available, but must not be presented as an all-effects workload.

Both baseline and candidate get identical optimization/instrumentation settings.
Hashing is disabled. Ordering alternates across repetitions to reduce bias. Each
export is read back and its count, timestamps, dimensions, duration and audio
presence/decodability checked. RSS is sampled once per second and saved to CSV.
By default completed deliverables are deleted after inspection to limit disk use;
`--keep-media` retains them. Timeouts and failures retain logs/partial results.

This new long-video harness has only syntax/helper validation from the Linux
integration session, not a native macOS type-check or executed hour-long run.
RSS covers the app process, including preparation and readback, not every encoder
service/GPU allocation. Peak RSS alone does not prove that memory plateaus.
Audio presence is not sample-exact equality or proof of long-term A/V sync. Review
those separately before a no-regression release decision.

## Portable tests and stored evidence

```bash
swiftc -O -swift-version 6 Screendrop/RecordingClipTimeline.swift \
  Screendrop/StudioExportScheduling.swift ExportReview/SchedulingTests.swift \
  -o /tmp/screendrop-scheduling-tests
/tmp/screendrop-scheduling-tests
python3 ExportReview/summarize_results.py /path/to/native/results
```

The scheduling suite performs 555,684 exact mapping comparisons and cancellation/
wakeup checks, including a two-hour timestamp schedule. It does not render two
hours of video. The evidence reader fails on mismatched pixel hashes and reports
audio sample counts without asserting they are identical.

## Diagnostic switches

- `SCREENDROP_STUDIO_EXPORT_DEPTH=1|2|3`, default 3, bounded pending slots.
- `SCREENDROP_STUDIO_EXPORT_REUSE=0` disables identical-state reuse.
- `SCREENDROP_STUDIO_EXPORT_TEXT_CACHE=0` disables Core Text layout reuse.
- `SCREENDROP_STUDIO_EXPORT_BACKEND=metal|coregraphics` selects the existing backend.
- Existing Mitchell and FP16 switches remain unchanged. Regression commands pin them.

DEBUG benchmarks are written to stderr and the existing
`~/Library/Application Support/Screendrop/DevExportBenchmarks.log`. A benchmark
with `SCREENDROP_STUDIO_EXPORT_DIGEST` enabled is not a pure throughput test.
