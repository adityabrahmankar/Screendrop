#!/usr/bin/env python3
"""Runs real AVFoundation/Metal exports; process isolation freezes environment.
Usage: run_native.py CANDIDATE_APP_EXECUTABLE BASELINE_APP_EXECUTABLE RESULTS
All media are generated fixtures, never user recordings. Every process has a timeout.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

candidate, baseline, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
fixtures = out / 'fixtures'
reports = []

def run(binary: Path, mode: str, label: str, *, depth='3', reuse='1', cache='1', backend='metal', digest=True):
    folder = out / label
    folder.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, SCREENDROP_EXPORT_REVIEW=mode,
               SCREENDROP_EXPORT_REVIEW_ROOT=str(fixtures),
               SCREENDROP_EXPORT_REVIEW_RESULT=str(folder),
               SCREENDROP_STUDIO_EXPORT_DEPTH=depth,
               SCREENDROP_STUDIO_EXPORT_REUSE=reuse,
               SCREENDROP_STUDIO_EXPORT_TEXT_CACHE=cache,
               SCREENDROP_STUDIO_EXPORT_BACKEND=backend,
               SCREENDROP_STUDIO_METAL_FILTER='mitchell',
               SCREENDROP_STUDIO_METAL_ACCUMULATION='fp16')
    if digest:
        env['SCREENDROP_STUDIO_EXPORT_DIGEST'] = str(folder / 'frames.csv')
    else:
        env.pop('SCREENDROP_STUDIO_EXPORT_DIGEST', None)
    started = time.monotonic()
    result = subprocess.run([str(binary)], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180, text=True)
    (folder / 'run.log').write_text(result.stdout)
    if result.returncode:
        print(result.stdout[-14000:], flush=True)
        raise RuntimeError(f'{label}: exit {result.returncode}')
    if mode not in ('prepare', 'invalid', 'cancel', 'cancel-immediate'):
        report = json.loads((folder / 'result.json').read_text())
        report.update(label=label, binary=str(binary), process_seconds=time.monotonic()-started)
        reports.append(report)
        reported_backend = 'coreGraphics' if backend == 'coregraphics' else backend
        assert f'backend={reported_backend}' in result.stdout, f'{label}: backend fell back or was not recorded'
    print(f'PASS {label} ({time.monotonic()-started:.2f}s process)', flush=True)
    return folder

run(candidate, 'prepare', 'prepare', digest=False)
cases = ('all', 'plain', 'crop', 'portrait', 'fit', 'wallpaper', 'hevc', 'mov', 'mute', 'replacement', 'static')
matched = 0
for backend in ('metal', 'coregraphics'):
    for mode in cases:
        # CG coverage is focused; all options additionally run through Metal.
        if backend == 'coregraphics' and mode not in ('all', 'crop', 'static'):
            continue
        old = run(baseline, mode, f'baseline-{backend}-{mode}', backend=backend, depth='1', reuse='0', cache='0')
        new = run(candidate, mode, f'candidate-{backend}-{mode}', backend=backend)
        a, b = (old/'frames.csv').read_bytes(), (new/'frames.csv').read_bytes()
        if a != b:
            aa, bb = a.splitlines(), b.splitlines()
            differences = [(i, x.decode(), y.decode()) for i, (x,y) in enumerate(zip(aa,bb)) if x != y]
            (out/'parity-failure.json').write_text(json.dumps(dict(case=mode, backend=backend,
                baseline_count=len(aa), candidate_count=len(bb), differences=differences[:10]), indent=2))
            raise AssertionError(f'raw pixel parity failed for {backend}/{mode}: {len(differences)} mismatches')
        matched += len(a.splitlines())
        # Keep a representative editable-free deliverable, not every duplicate movie.
        if mode != 'all':
            for folder in (old, new):
                for movie in folder.glob('export.*'): movie.unlink()

for mode in ('cancel-immediate', 'cancel', 'invalid'):
    run(candidate, mode, mode, digest=False)

# Hashing is disabled for timing. Static/VFR fixture intentionally exposes reuse;
# it must never be represented as a universal speedup for dynamic camera footage.
for iteration in range(3):
    run(baseline, 'benchmark', f'bench-baseline-{iteration}', depth='1', reuse='0', cache='0', digest=False)
    run(candidate, 'benchmark', f'bench-candidate-{iteration}', digest=False)
    for folder in (out/f'bench-baseline-{iteration}', out/f'bench-candidate-{iteration}'):
        for movie in folder.glob('export.*'): movie.unlink()

summary = dict(matched_raw_frames=matched, reference='pass1 2e891f6; probe + fixture hook only',
               cases=list(cases), reports=reports)
(out/'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True))
print(f'PASS: {matched} full-frame hashes equal; frame count/PTS/audio readback; cancellation; 3 timing pairs', flush=True)
