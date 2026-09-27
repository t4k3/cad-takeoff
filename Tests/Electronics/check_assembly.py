#!/usr/bin/env python3
"""Independent CSV/JSON consumer: no Swift implementation or exporter logic imported.

Golden values refer to the synthetic two-sided fixture, not to an actual purchasable PCB.
"""
import csv
import json
import math
import sys
from pathlib import Path

root = Path(sys.argv[1])
with (root / 'BOM.csv').open(newline='') as f:
    bom = list(csv.DictReader(f))
with (root / 'CPL.csv').open(newline='') as f:
    cpl = list(csv.DictReader(f))
assembly = json.loads((root / 'assembly.json').read_text())
assert len(bom) == 2, bom
assert {r['LCSC Part #'] for r in bom} == {'C000000101', 'C000000102'}
assert all(r['Comment'] == '10k, 1% "thin"' for r in bom)
refs = [ref for row in bom for ref in row['Designator'].split(',')]
assert set(refs) == {row['Designator'] for row in cpl} == {'R1', 'R2', 'R5', 'R6'}
assert len(refs) == len(set(refs)) == len(cpl)
golden = {'R1': (10.1, 20.2, 'Top', 180), 'R2': (30.1, 19.8, 'Bottom', 90),
          'R5': (33.9, 7.8, 'Top', 0), 'R6': (44.1, 8.2, 'Top', 180)}
for row in cpl:
    x, y, side, angle = golden[row['Designator']]
    assert math.isclose(float(row['Mid X']), x, abs_tol=1e-6)
    assert math.isclose(float(row['Mid Y']), y, abs_tol=1e-6)
    assert row['Layer'] == side
    assert float(row['Rotation']) == angle
assert assembly['fabricationReady'] is False
assert assembly['documentRevision'] == 0
assert 'model_assets_unchecked' in {i['code'] for i in assembly['issues']}
assert {i['reference'] for i in assembly['instances3D']} == {'R1', 'R2', 'R4', 'R5', 'R6'}
for instance in assembly['instances3D']:
    m = instance['transform']
    assert len(m) == 16 and all(math.isfinite(v) for v in m)
    for r in range(3):
        for s in range(3):
            assert math.isclose(sum(m[4*r+k] * m[4*s+k] for k in range(3)), int(r == s), abs_tol=1e-9)
    determinant = (m[0]*(m[5]*m[10]-m[6]*m[9]) - m[1]*(m[4]*m[10]-m[6]*m[8])
                   + m[2]*(m[4]*m[9]-m[5]*m[8]))
    assert math.isclose(determinant, 1, abs_tol=1e-9)
    assert math.isclose(m[11], -0.3 if instance['side'] == 'bottom' else 1.9, abs_tol=1e-9)
assert len(assembly['connectivity']['pads']) == 10
assert len(assembly['connectivity']['airwires']) == 8
print('PASS: independent BOM/CPL consistency, CSV quoting, DNP/manual selection, centroids, rotations, 3D rigid transforms, connectivity.')
