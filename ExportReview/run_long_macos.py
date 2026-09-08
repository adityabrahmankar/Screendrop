#!/usr/bin/env python3
"""Build isolated optimized diagnostic apps and compare long native exports.
Defaults to one hour of looped synthetic footage. Not a physical-Mac performance
claim until this command has completed on that Mac. No user recordings are used.
"""
from __future__ import annotations
import argparse
import csv
import json
import os
from pathlib import Path
import platform
import shutil
from statistics import median
import subprocess
import tarfile
import tempfile
import time

BASELINE = '2e891f6ac625fe10c48d8e0f03506dc575e879b3'


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f'Fixture hook must occur exactly once: {old[:80]!r}')
    return text.replace(old, new, 1)


def inject(root: Path, extra: str) -> None:
    path = root / 'Screendrop/StudioExportReview.swift'
    text = path.read_text()
    text = replace_once(text, 'import CoreGraphics\n', 'import CoreGraphics\nimport CoreMedia\n')
    text = replace_once(text, '        if mode == "prepare" {', '''        let longSeconds = Double(env["SCREENDROP_EXPORT_REVIEW_SECONDS"] ?? "3600") ?? 3600
        try require(longSeconds.isFinite && longSeconds >= 4 && longSeconds <= 7200, "invalid long duration")
        if mode == "prepare-long" {
            try await prepareLong(root, seconds: longSeconds)
            return
        }
        if mode == "prepare" {''')
    text = replace_once(text, '        let config = configuration(root, mode: mode)', '''        let config = mode.hasPrefix("soak-")
            ? longConfiguration(root, seconds: longSeconds, effects: mode == "soak-effects")
            : configuration(root, mode: mode)''')
    text = replace_once(text, '    private static func prepare(_ root: URL) async throws {',
                        extra + '\n    private static func prepare(_ root: URL) async throws {')
    path.write_text(text)


def command(args: list[str], log: Path, *, env: dict | None = None, timeout: float = 1800) -> None:
    with log.open('w') as handle:
        subprocess.run(args, stdout=handle, stderr=subprocess.STDOUT, check=True,
                       env=env, timeout=timeout)


def build(root: Path, derived: Path, log: Path) -> Path:
    # Release optimization with DEBUG diagnostic hooks. This is NOT the shipping
    # Release binary. Both baseline and candidate get identical build settings.
    command(['xcodebuild', 'build', '-project', str(root / 'Screendrop.xcodeproj'),
             '-scheme', 'Screendrop', '-configuration', 'Release', '-destination', 'generic/platform=macOS',
             '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64',
             'ONLY_ACTIVE_ARCH=YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG'], log)
    return derived / 'Build/Products/Release/Screendrop.app/Contents/MacOS/Screendrop'


def export(binary: Path, env: dict, folder: Path, timeout: float) -> dict:
    folder.mkdir()
    start = time.monotonic()
    samples = []
    with (folder / 'run.log').open('w') as log:
        process = subprocess.Popen([str(binary)], env=dict(env, SCREENDROP_EXPORT_REVIEW_RESULT=str(folder)),
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - start
                if elapsed > timeout:
                    raise TimeoutError(f'Native export exceeded {timeout}s. See {folder}')
                rss = subprocess.run(['ps', '-o', 'rss=', '-p', str(process.pid)],
                                     text=True, capture_output=True, timeout=5).stdout.strip()
                if rss.isdigit():
                    samples.append((elapsed, int(rss)))
                time.sleep(1)
            if process.returncode:
                raise RuntimeError(f'Native process exit {process.returncode}. See {folder}')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            with (folder / 'rss.csv').open('w', newline='') as handle:
                writer = csv.writer(handle); writer.writerow(['process_elapsed_seconds', 'rss_kib'])
                writer.writerows(samples)
    report = json.loads((folder / 'result.json').read_text())
    if report['digest_enabled']:
        raise ValueError('Timing run unexpectedly enabled pixel hashing')
    if 'backend=metal' not in (folder / 'run.log').read_text():
        raise ValueError('Metal path not confirmed; refusing to report fallback as GPU performance')
    report['process_seconds'] = time.monotonic() - start
    report['peak_process_rss_kib'] = max((rss for _, rss in samples), default=0)
    report['rss_scope'] = 'whole process including timeline preparation and output readback; not total system/GPU/encoder memory'
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--baseline-archive', type=Path)
    parser.add_argument('--seconds', type=int, default=3600)
    parser.add_argument('--scenario', choices=('effects', 'static'), default='effects')
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=None, help='Per export process seconds, includes output readback')
    parser.add_argument('--keep-media', action='store_true', help='Retain each generated deliverable; can use substantial disk space')
    args = parser.parse_args()
    if not 4 <= args.seconds <= 7200 or not 1 <= args.repetitions <= 5:
        parser.error('seconds must be 4..7200; repetitions must be 1..5')
    if args.timeout is not None and args.timeout <= 0:
        parser.error('timeout must be positive')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('Requires Apple Silicon macOS and Xcode 26.4 or later')
    root, results = args.source.resolve(), args.results.resolve()
    results.mkdir(parents=True, exist_ok=False)
    environment = {'build': 'Release -O with DEBUG diagnostics, hashing disabled', 'source': str(root)}
    for label, cmd in [('os', ['sw_vers']), ('xcode', ['xcodebuild', '-version']),
                       ('gpu', ['system_profiler', 'SPDisplaysDataType'])]:
        environment[label] = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    (results / 'environment.json').write_text(json.dumps(environment, indent=2))
    with tempfile.TemporaryDirectory(prefix='screendrop-long-') as work_string:
        work = Path(work_string)
        candidate, baseline = work / 'candidate', work / 'baseline'
        shutil.copytree(root, candidate, ignore=shutil.ignore_patterns('.git', 'build', 'DerivedData', '__pycache__'))
        baseline.mkdir()
        if args.baseline_archive:
            with tarfile.open(args.baseline_archive) as archive:
                archive.extractall(baseline, filter='data')
        else:
            archive_file = work / 'baseline.tar'
            with archive_file.open('wb') as handle:
                subprocess.run(['git', '-C', str(root), 'archive', BASELINE], stdout=handle, check=True)
            with tarfile.open(archive_file) as archive:
                archive.extractall(baseline, filter='data')
        command(['python3', str(root / 'ExportReview/prepare_baseline.py'), str(candidate), str(baseline)],
                results / 'baseline-injection.log')
        extra = (root / 'ExportReview/LongFixture.swift.inc').read_text()
        inject(candidate, extra); inject(baseline, extra)
        old = build(baseline, work / 'old-build', results / 'baseline-build.log')
        new = build(candidate, work / 'new-build', results / 'candidate-build.log')
        fixtures = work / 'fixtures'
        env = dict(os.environ, SCREENDROP_EXPORT_REVIEW='prepare-long',
                   SCREENDROP_EXPORT_REVIEW_ROOT=str(fixtures),
                   SCREENDROP_EXPORT_REVIEW_SECONDS=str(args.seconds),
                   SCREENDROP_STUDIO_EXPORT_BACKEND='metal', SCREENDROP_STUDIO_METAL_FILTER='mitchell',
                   SCREENDROP_STUDIO_METAL_ACCUMULATION='fp16')
        env.pop('SCREENDROP_STUDIO_EXPORT_DIGEST', None)
        command([str(new)], results / 'fixture-generation.log', env=env,
                timeout=max(600, args.seconds * 4))
        env['SCREENDROP_EXPORT_REVIEW'] = f'soak-{args.scenario}'
        records = []
        for i in range(args.repetitions):
            # Alternate ordering to reduce a systematic warm-cache/thermal bias.
            for label in (('baseline', 'candidate') if i % 2 == 0 else ('candidate', 'baseline')):
                old_path = label == 'baseline'
                process_env = dict(env, SCREENDROP_STUDIO_EXPORT_DEPTH='1' if old_path else '3',
                                   SCREENDROP_STUDIO_EXPORT_REUSE='0' if old_path else '1',
                                   SCREENDROP_STUDIO_EXPORT_TEXT_CACHE='0' if old_path else '1')
                folder = results / f'{label}-{i}'
                report = export(old if old_path else new, process_env, folder, args.timeout or max(600, args.seconds * 8))
                report.update(label=label, iteration=i)
                records.append(report)
                (results / 'partial-results.json').write_text(json.dumps(records, indent=2))
                if not args.keep_media:
                    for media in folder.glob('export.*'):
                        media.unlink()
                print(f'Completed {label} run {i + 1}: {report["wall_seconds"]:.3f}s', flush=True)
        previous = median(r['wall_seconds'] for r in records if r['label'] == 'baseline')
        current = median(r['wall_seconds'] for r in records if r['label'] == 'candidate')
        summary = dict(seconds=args.seconds, scenario=args.scenario, records=records,
                       baseline_median=previous, candidate_median=current, speedup=previous / current,
                       limitations=['Looped synthetic source, not every real recording or codec.',
                                    'Checks frame count, PTS, dimensions and audio readback, not sample-exact audio or visual quality.',
                                    'Inspect rss.csv for growth; one peak value does not prove a memory plateau.'])
        (results / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(f'Results: {results}')


if __name__ == '__main__':
    main()
