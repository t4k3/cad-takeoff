#!/usr/bin/env python3
"""Independent geometry/placement/lot reader: no dependency on the Swift implementation.
Usage: check_manufacturing_assembly.py BINARY INPUT.ftkc NEW_REPORT.json
"""
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

binary, source, output = sys.argv[1:]
source, output = Path(source), Path(output)
original = source.read_bytes()
subprocess.run([binary, str(source), str(output)], check=True)
assert source.read_bytes() == original, 'Input document changed'
report = json.loads(output.read_text())
document = json.loads(original)
package = document['design']['manufacturing']
assert report['sourceRevision'] == document['revision'] and report['packageID'] == package['id']
lot = next(x for x in package['lots'] if x['id'] == package['activeLotID'])
fitted = set(lot['fittedComponentIDs'])
components = {x['id']: x for x in package['components']}
assert len(report['instances']) == len(components)
assert {x['id'] for x in report['instances']} == set(components)
assert report['boardThickness'] > 0 and report['boardParts'], 'Actual substrate required'
assert any(x['fitted'] and x['parts'] for x in report['instances']), 'No component geometry exercised'

def xyz(p):
    return tuple(p[k] for k in ('x', 'y', 'z'))

def mesh(part):
    vertices = list(map(xyz, part['vertices']))
    indices = part['indices']
    assert len(indices) >= 12 and len(indices) % 3 == 0
    assert all(math.isfinite(v) for p in vertices for v in p)
    assert all(type(i) is int and 0 <= i < len(vertices) for i in indices)
    # Count by coordinates, so duplicate face-local vertices still have to close.
    edges = Counter()
    volume = 0.0
    origin = vertices[0]
    for i in range(0, len(indices), 3):
        pts = [vertices[j] for j in indices[i:i+3]]
        assert len(set(pts)) == 3, 'Degenerate triangle'
        for a,b in zip(pts, pts[1:]+pts[:1]):
            edges[(a,b)] += 1
        a,b,c = [tuple(p[j]-origin[j] for j in range(3)) for p in pts]
        cross = (b[1]*c[2]-b[2]*c[1], b[2]*c[0]-b[0]*c[2], b[0]*c[1]-b[1]*c[0])
        volume += sum(a[j]*cross[j] for j in range(3))/6
    assert all(n == 1 and edges[(b,a)] == 1 for (a,b),n in edges.items()), 'Mesh is not closed and consistently wound'
    assert volume > 1e-9, 'Nonpositive outward volume'
    return volume

for part in report['boardParts']:
    mesh(part)
    assert min(p['z'] for p in part['vertices']) == 0
    assert max(p['z'] for p in part['vertices']) == report['boardThickness']

for instance in report['instances']:
    c = components[instance['id']]
    assert instance['reference'] == c['reference'] and instance['fitted'] == (c['id'] in fitted)
    assert instance['quality'] in ('missing','approximate'), 'Initial catalog does not certify models'
    placement = c.get('placement')
    if not placement:
        assert not instance['parts'] and not instance.get('transform') and not instance.get('position')
        continue
    assert instance['side'] == placement['side'] and instance['position'] == placement['position']
    if not instance['parts']:
        assert instance['quality'] == 'missing'
        continue
    transform = instance['transform']
    assert len(transform) == 16 and all(math.isfinite(v) for v in transform)
    a,b,c0 = transform[0:3], transform[4:7], transform[8:11]
    determinant = a[0]*(b[1]*c0[2]-b[2]*c0[1])-a[1]*(b[0]*c0[2]-b[2]*c0[0])+a[2]*(b[0]*c0[1]-b[1]*c0[0])
    assert math.isclose(determinant, 1, abs_tol=1e-9), 'Bottom placement must not reflect the mesh'
    if not components[instance['id']].get('modelBinding'):
        assert math.isclose(transform[3], placement['position']['x'], abs_tol=1e-9)
        assert math.isclose(transform[7], placement['position']['y'], abs_tol=1e-9)
        assert math.isclose(transform[11], report['boardThickness'] if placement['side']=='top' else 0, abs_tol=1e-9)
    for part in instance['parts']:
        mesh(part)
    assert len({p['id'] for p in instance['parts']}) == len(instance['parts'])

before = hashlib.sha256(output.read_bytes()).hexdigest()
second = subprocess.run([binary, str(source), str(output)], capture_output=True)
assert second.returncode != 0 and hashlib.sha256(output.read_bytes()).hexdigest() == before, 'Never overwrite'
print('PASS independent assembled PCB: closed CCW geometry, placements, lot flags, missing positions, immutable input/output.')
