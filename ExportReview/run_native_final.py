#!/usr/bin/env python3
"""Compare independent pass1 and pass2 app binaries using generated media.
Usage: run_native.py CANDIDATE_EXECUTABLE BASELINE_EXECUTABLE RESULTS
Hashes are disabled for benchmarks. Set SCREENDROP_RUN_SOAK=1 for the hour test.
All subprocesses have deadlines. This script never opens a user's recordings.
"""
from __future__ import annotations
import json
import array
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

if len(sys.argv) != 4:
    raise SystemExit(__doc__)
candidate, baseline, out = (Path(arg).resolve() for arg in sys.argv[1:])
for binary in (candidate, baseline):
    if not binary.is_file():
        raise SystemExit(f"Missing app executable: {binary}")
out.mkdir(parents=True, exist_ok=True)
fixtures = out / 'fixtures'
reports: list[dict] = []
matched = 0
audio_matched = 0
audio_tail_variations: list[dict] = []
audio_reference_variants: list[dict] = []
audio_variant_matches: list[dict] = []

def metrics(log: str) -> dict:
    values = {}
    for line in log.splitlines():
        key, sep, value = line.partition('=')
        if sep and key.replace('_', '').isalnum():
            try:
                values[key] = float(value)
            except ValueError:
                values[key] = value
    return values

def run(binary: Path, mode: str, label: str, *, depth='3', reuse='1', cache='1', backend='metal', digest=True):
    folder = out / label
    folder.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('SCREENDROP_')}
    env.update(SCREENDROP_EXPORT_REVIEW=mode,
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
        env['SCREENDROP_STUDIO_EXPORT_AUDIO_DIGEST'] = str(folder / 'audio.json')
    if mode.startswith('fail-'):
        env['SCREENDROP_EXPORT_REVIEW_FAULT'] = mode.removeprefix('fail-')
    started = time.monotonic()
    rss = []
    deadline = 900 if mode == 'soak' else 300
    with (folder / 'run.log').open('w') as log:
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                if time.monotonic() - started > deadline:
                    raise TimeoutError(f'{label}: exceeded {deadline}s')
                if mode == 'soak':
                    result = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(process.pid)],
                                            capture_output=True, text=True, timeout=3)
                    if result.returncode == 0 and result.stdout.strip():
                        rss.append([time.monotonic()-started, int(result.stdout.strip())])
                time.sleep(0.25)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
    text = (folder / 'run.log').read_text()
    if process.returncode:
        print(text[-16000:], flush=True)
        raise RuntimeError(f'{label}: exit {process.returncode}')
    if mode not in ('prepare', 'invalid', 'cancel', 'cancel-immediate') and not mode.startswith('fail-'):
        report = json.loads((folder / 'result.json').read_text())
        report.update(label=label, process_seconds=time.monotonic()-started, stages=metrics(text))
        reports.append(report)
        expected_backend = 'coreGraphics' if backend == 'coregraphics' else backend
        assert f'backend={expected_backend}' in text, f'{label}: backend fallback'
        if binary == candidate:
            assert report['stages']['peak_slots'] <= report['stages']['pipeline_depth'] <= 3
        if rss:
            (folder / 'rss-kib.json').write_text(json.dumps(rss))
            warm = [x[1] for x in rss if x[0] >= 5]
            assert len(warm) >= 6, 'soak memory sampling incomplete'
            third = max(1, len(warm)//3)
            growth = statistics.median(warm[-third:]) - statistics.median(warm[:third])
            report['memory'] = dict(peak_rss_mib=max(warm)/1024, late_minus_early_mib=growth/1024,
                                    samples=len(warm), resolution='160x90', media_duration=3600)
            assert growth < 128*1024, f'soak RSS grew by {growth/1024:.1f} MiB'
            assert report['media']['frames'] == 216000
    print(f'PASS {label} ({time.monotonic()-started:.2f}s process)', flush=True)
    return folder

def compare(mode: str, backend: str = 'metal', depth: str = '3'):
    global matched, audio_matched
    suffix = f'{backend}-{mode}-depth{depth}'
    old = run(baseline, mode, f'baseline-{suffix}', backend=backend, depth='1', reuse='0', cache='0')
    new = run(candidate, mode, f'candidate-{suffix}', backend=backend, depth=depth)
    a, b = (old/'frames.csv').read_bytes(), (new/'frames.csv').read_bytes()
    if a != b:
        aa, bb = a.splitlines(), b.splitlines()
        differences = [(i, x.decode(), y.decode()) for i, (x,y) in enumerate(zip(aa,bb)) if x != y]
        (out/'parity-failure.json').write_text(json.dumps(dict(case=mode, backend=backend,
            baseline_count=len(aa), candidate_count=len(bb), differences=differences[:10]), indent=2))
        raise AssertionError(f'raw pixel parity failed for {suffix}')
    matched += len(a.splitlines())
    assert (old/'audio.json').exists() == (new/'audio.json').exists(), f'{suffix}: audio disappeared'
    if (old/'audio.json').exists():
        old_audio, new_audio = (json.loads((x/'audio.json').read_text()) for x in (old,new))
        if old_audio['in_timeline'] != new_audio['in_timeline']:
            # These fixtures have identical source audio, clip edits and settings;
            # only their video/overlay/container configuration differs. The fixed
            # baseline-only repeatability corpus is collected BEFORE candidates.
            same_audio_edits = mode in ('all', 'plain', 'crop', 'portrait', 'fit',
                'wallpaper', 'hevc', 'mov', 'no-overlays', 'camera-hidden', '4k')
            matches = [i for i, variant in enumerate(audio_reference_variants)
                       if variant == new_audio['in_timeline']] if same_audio_edits else []
            assert matches, f'{suffix}: PCM/timing is not byte-exact to any observed independent baseline: {old_audio} vs {new_audio}'
            audio_variant_matches.append(dict(case=suffix, exact_baseline_variant=matches[0],
                reason='Independent baseline itself produces more than one PCM realization'))
        if old_audio['full_stream'] != new_audio['full_stream']:
            audio_tail_variations.append(dict(case=suffix, baseline=old_audio, candidate=new_audio))
        audio_matched += 1
    if mode != 'all':
        for folder in (old, new):
            for movie in folder.glob('export.*'): movie.unlink()

run(candidate, 'prepare', 'prepare', digest=False)
# Measure repeatability before evaluating the candidate. Do not invent a numeric
# quality tolerance or repeatedly rerun until the candidate happens to match.
reference_folders = []
for iteration in range(8):
    folder = run(baseline, 'all', f'baseline-repeatability-{iteration}', depth='1', reuse='0', cache='0')
    audio = json.loads((folder/'audio.json').read_text())['in_timeline']
    if audio not in audio_reference_variants:
        audio_reference_variants.append(audio)
        reference_folders.append(folder)
    for movie in folder.glob('export.*'): movie.unlink()
repeatability_differences = []
for folder in reference_folders[1:]:
    for plane in sorted(reference_folders[0].glob('audio.plane*.pcm')):
        other = folder / plane.name
        a, b = array.array('f'), array.array('f')
        a.frombytes(plane.read_bytes()); b.frombytes(other.read_bytes())
        if sys.byteorder != 'little':
            a.byteswap(); b.byteswap()
        assert len(a) == len(b), 'Baseline in-cut sample count is not repeatable'
        changed = [i for i, (x, y) in enumerate(zip(a, b)) if x != y]
        squared_error = sum((x-y)**2 for x,y in zip(a,b))
        energy = sum(x*x for x in a)
        repeatability_differences.append(dict(reference=str(reference_folders[0].name),
            alternate=str(folder.name), plane=plane.name, changed_scalar_samples=len(changed),
            first_changed_scalar=changed[0] if changed else None,
            last_changed_scalar=changed[-1] if changed else None,
            peak_absolute_difference=max((abs(x-y) for x,y in zip(a,b)), default=0),
            snr_db=10*math.log10(energy/squared_error) if squared_error and energy else None))
(out/'baseline-repeatability.json').write_text(json.dumps(dict(runs=8,
    variants=audio_reference_variants, differences=repeatability_differences), indent=2))
print(f'Baseline-only audio repeatability: {len(audio_reference_variants)} distinct in-cut PCM realizations across 8 exports', flush=True)
cases = ('all', 'plain', 'crop', 'portrait', 'fit', 'wallpaper', 'hevc', 'mov', 'mute',
         'replacement', 'static', 'no-overlays', 'camera-hidden', '4k', 'audio-unretimed')
for mode in cases:
    compare(mode)
for mode in ('all', 'crop', 'static'):
    compare(mode, backend='coregraphics')
for depth in ('1', '2'):
    compare('all', depth=depth)
for mode in ('cancel-immediate', 'cancel', 'invalid', 'fail-video', 'fail-audio', 'fail-writer'):
    run(candidate, mode, mode, digest=False)

for mode in ('benchmark', 'benchmark-dynamic'):
    for iteration in range(3):
        pairs = [(baseline, 'baseline'), (candidate, 'candidate')]
        if iteration % 2: pairs.reverse()
        for binary, name in pairs:
            folder = run(binary, mode, f'{mode}-{name}-{iteration}', depth='1' if name=='baseline' else '3',
                         reuse='0' if name=='baseline' else '1', cache='0' if name=='baseline' else '1', digest=False)
            for movie in folder.glob('export.*'): movie.unlink()

if os.environ.get('SCREENDROP_RUN_SOAK') == '1':
    folder = run(candidate, 'soak', 'soak', digest=False)
    for movie in folder.glob('export.*'): movie.unlink()
summary = dict(matched_raw_frames=matched, matched_pcm_cases=audio_matched,
               reference='pass1 2e891f6; identical fixture entry point + observation probes only',
               cases=list(cases), reports=reports, out_of_cut_audio_tail_variations=audio_tail_variations,
               baseline_audio_repeatability=dict(runs=8, variants=audio_reference_variants,
                   differences=repeatability_differences), exact_audio_variant_matches=audio_variant_matches)
(out/'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True))
print(f'PASS: {matched} complete-frame hashes equal; {audio_matched} in-cut PCM matches to observed baseline realizations; PTS/readback; cancellation/faults', flush=True)
