#!/usr/bin/env python3
"""Recheck stored native evidence. No native runtime or third-party packages needed."""
from __future__ import annotations
import argparse
import csv
import json
from pathlib import Path
from statistics import median


def summarize(root: Path) -> dict:
    document = json.loads((root / 'summary.json').read_text())
    matches = 0
    compared = []
    for backend in ('metal', 'coregraphics'):
        for case in document['cases']:
            a = root / f'baseline-{backend}-{case}'
            b = root / f'candidate-{backend}-{case}'
            if backend == 'coregraphics' and case not in ('all', 'crop', 'static'):
                continue
            old, new = (a / 'frames.csv').read_bytes(), (b / 'frames.csv').read_bytes()
            if not old or old != new:
                raise ValueError(f'Frame parity failed: {backend}/{case}')
            rows = list(csv.reader(old.decode().splitlines()))
            for index, row in enumerate(rows):
                if len(row) != 4 or int(row[0]) != index or int(row[2]) <= 0 or len(row[3]) != 64:
                    raise ValueError(f'Invalid digest row: {backend}/{case}/{index}')
                int(row[3], 16)
            matches += len(rows)
            previous = json.loads((a / 'result.json').read_text())
            current = json.loads((b / 'result.json').read_text())
            for field in ('frames', 'width', 'height', 'audio_tracks'):
                if previous['media'][field] != current['media'][field]:
                    raise ValueError(f'Media mismatch {backend}/{case}/{field}')
            # Container/AAC packet endpoints are deliberately reported, not
            # mislabeled as bit-exact audio equivalence.
            compared.append(dict(backend=backend, case=case, frames=len(rows),
                baseline_seconds=previous['wall_seconds'], candidate_seconds=current['wall_seconds'],
                baseline_audio_samples=previous['media']['decoded_audio_samples'],
                candidate_audio_samples=current['media']['decoded_audio_samples'],
                baseline_duration=previous['media']['duration_seconds'],
                candidate_duration=current['media']['duration_seconds']))
    old_runs, new_runs = [], []
    for i in range(3):
        a = json.loads((root / f'bench-baseline-{i}' / 'result.json').read_text())
        b = json.loads((root / f'bench-candidate-{i}' / 'result.json').read_text())
        if a['digest_enabled'] or b['digest_enabled']:
            raise ValueError('Do not present digest-enabled runs as throughput benchmarks')
        old_runs.append(a['wall_seconds']); new_runs.append(b['wall_seconds'])
    return dict(matched_raw_frames=matches, cases=compared,
        timing=dict(workload='30-second static 1080p60, not dynamic/hour-long footage',
                    baseline=old_runs, candidate=new_runs, baseline_median=median(old_runs),
                    candidate_median=median(new_runs), median_speedup=median(old_runs)/median(new_runs)),
        limitations=['Hashes compare pixels before encoding, not encoded-file bytes.',
                     'Audio presence/readback is tested, not sample-exact equality or long-term sync.',
                     'GPU/model and build configuration must accompany every performance claim.'])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.results), indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
