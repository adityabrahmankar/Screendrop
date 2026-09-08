#!/bin/bash
# Build and exercise normal committed sources, never staged/base64 candidates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="${1:-${TMPDIR:-/tmp}/screendrop-export-validation-$(date +%Y%m%d-%H%M%S)}"
BASELINE=2e891f6ac625fe10c48d8e0f03506dc575e879b3
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'Native validation requires an Apple Silicon Mac and Xcode 26.4 or later.' >&2
  exit 2
fi
if [ -e "$RESULTS" ]; then
  echo "Refusing to reuse results directory: $RESULTS" >&2
  exit 2
fi
mkdir -p "$RESULTS"
RESULTS="$(cd "$RESULTS" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/screendrop-native.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
{ sw_vers; uname -m; xcodebuild -version; system_profiler SPDisplaysDataType; } > "$RESULTS/environment.txt"
cd "$ROOT"
xcrun swiftc -O -swift-version 6 Screendrop/RecordingClipTimeline.swift \
  Screendrop/StudioExportScheduling.swift ExportReview/SchedulingTests.swift \
  -o "$WORK/scheduling-tests"
"$WORK/scheduling-tests" | tee "$RESULTS/scheduling-tests.txt"

build() {
  local root="$1" configuration="$2" derived="$3" label="$4"
  local status=0
  xcodebuild build -project "$root/Screendrop.xcodeproj" -scheme Screendrop \
    -configuration "$configuration" -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    > "$RESULTS/$label.log" 2>&1 || status=$?
  grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' "$RESULTS/$label.log" | tail -50 || true
  return "$status"
}
build "$ROOT" Debug "$WORK/debug" candidate-debug
build "$ROOT" Release "$WORK/release" candidate-release
mkdir -p "$WORK/baseline"
if [ -n "${SCREENDROP_BASELINE_ARCHIVE:-}" ]; then
  tar -xzf "$SCREENDROP_BASELINE_ARCHIVE" -C "$WORK/baseline"
elif git -C "$ROOT" cat-file -e "$BASELINE^{commit}" 2>/dev/null; then
  git -C "$ROOT" archive "$BASELINE" | tar -x -C "$WORK/baseline"
else
  echo 'Set SCREENDROP_BASELINE_ARCHIVE to the supplied reference/pass1.tar.gz.' >&2
  exit 2
fi
python3 ExportReview/prepare_baseline.py "$ROOT" "$WORK/baseline"
build "$WORK/baseline" Debug "$WORK/baseline-build" baseline-debug
python3 ExportReview/run_native.py \
  "$WORK/debug/Build/Products/Debug/Screendrop.app/Contents/MacOS/Screendrop" \
  "$WORK/baseline-build/Build/Products/Debug/Screendrop.app/Contents/MacOS/Screendrop" \
  "$RESULTS/native" | tee "$RESULTS/native-tests.log"
python3 ExportReview/summarize_results.py "$RESULTS/native" > "$RESULTS/summary.json"
echo "Validation finished. Results: $RESULTS"
