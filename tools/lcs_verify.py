#!/usr/bin/env python3
"""Final sequential checks; requires loopback UDP permission, no external service."""
import pathlib
import sys
import subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/lcs-verification'
OUT.mkdir(parents=True, exist_ok=True)
checks = [
    ('startups', ['python3', 'tools/lcs_startup_test.py'], 240),
    ('progressive', ['python3', 'tools/lcs_benchmark.py'], 240),
    ('two-clients', ['python3', 'tools/lcs_network_test.py'], 100),
    ('full-match', ['godot', '--headless', '--fixed-fps', '60', '-s', 'res://tests/lcs_match_test.gd', '--',
        '--lcs-server', '--players=10', '--port=27975', '--queue-seconds=0', '--match-seed=2026', '--bench',
        '--report=' + str(OUT / 'full-match.json')], 200),
    ('100-connections', ['python3', 'tools/lcs_load_test.py'], 100),
]
for name, command, limit in checks:
    if len(sys.argv) > 1 and name not in sys.argv[1:]:
        continue
    print('RUN', name, flush=True)
    with (OUT / (name + '.log')).open('w') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=limit)
    text = (OUT / (name + '.log')).read_text()
    if result.returncode or 'SCRIPT ERROR' in text or 'NET FAIL' in text:
        print(text[-8000:], flush=True)
        raise SystemExit(f'FAIL {name}: {result.returncode}')
    print('PASS', name, flush=True)
print('LCS verification PASS', flush=True)
