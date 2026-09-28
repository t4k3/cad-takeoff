#!/usr/bin/env python3
"""Independent reader: recompute coverage, distances and connectivity from exported polygons.
Python standard library only; never calls the Swift fill, DRC or connectivity engine.
"""
import json
import math
import sys
from pathlib import Path

root = Path(sys.argv[1])
def read(name):
    return json.loads((root / name).read_text())
def point(p):
    return p['x'], p['y']
def edges(p):
    return list(zip(p, p[1:] + p[:1]))
def cross(a, b, c):
    return (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])
def point_segment(p, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    length = dx*dx+dy*dy
    t = max(0, min(1, ((p[0]-a[0])*dx+(p[1]-a[1])*dy)/length)) if length else 0
    return math.hypot(p[0]-a[0]-t*dx, p[1]-a[1]-t*dy)
def segment_gap(a, b, c, d):
    if cross(a,b,c)*cross(a,b,d)<0 and cross(c,d,a)*cross(c,d,b)<0:
        return 0
    return min(point_segment(a,c,d), point_segment(b,c,d), point_segment(c,a,b), point_segment(d,a,b))
def inside(p, polygon):
    # Convex filled cells, CCW. A point on the boundary is considered copper.
    return all(cross(a,b,p)>=-1e-8 for a,b in edges(polygon))
def area(p):
    return sum(a[0]*b[1]-a[1]*b[0] for a,b in edges(p))/2
def gap(a, b):
    if inside(a[0], b) or inside(b[0], a):
        return 0
    return min(segment_gap(*x,*y) for x in edges(a) for y in edges(b))
def groups(cells, bridge=False):
    parent = list(range(len(cells)))
    def find(i):
        while parent[i]!=i:
            parent[i]=parent[parent[i]]; i=parent[i]
        return i
    def join(a,b):
        parent[find(a)]=find(b)
    boxes = [(min(x for x,y in p), min(y for x,y in p), max(x for x,y in p), max(y for x,y in p)) for p in cells]
    for i,a in enumerate(cells):
        for j,b in enumerate(cells[:i]):
            x,y=boxes[i],boxes[j]
            if x[2]+1e-7<y[0] or y[2]+1e-7<x[0] or x[3]+1e-7<y[1] or y[3]+1e-7<x[1]:
                continue
            if gap(a,b)<=1e-7:
                join(i,j)
    if bridge:
        hits=[i for i,p in enumerate(cells) if any(segment_gap((20,10),(30,10),a,b)<=.2+1e-7 for a,b in edges(p)) or inside((20,10),p) or inside((30,10),p)]
        for j in hits[1:]:
            join(hits[0],j)
    left=next(i for i,p in enumerate(cells) if inside((8.825,10),p))
    right=next(i for i,p in enumerate(cells) if inside((40.825,10),p))
    return len({find(i) for i in range(len(cells))}), find(left)==find(right)

for name, expected in [('connected',True),('split',False),('bridged',True),('undo',False),('redo',True)]:
    data=read(f'zones-{name}.json'); doc=read(f'zones-{name}.ftkc')
    assert doc['formatVersion']==8
    assert not any(i['severity']=='error' for i in data['issues'])
    zone=data['zones'][0]; cells=[[point(p) for p in c] for c in zone['cells']]
    assert cells and all(area(c)>0 for c in cells)
    assert abs(sum(area(c) for c in cells)-zone['area'])<1e-7
    # Board inset is .25; independent foreign track capsule has radius .25 + .75 = 1.
    for c in cells:
        for x,y in c:
            assert .25-1e-8<=x<=49.75+1e-8 and .25-1e-8<=y<=29.75+1e-8
        assert not inside((25,20),c)
        assert min(segment_gap((12,20),(38,20),a,b) for a,b in edges(c))>=1-1e-8
        if name!='connected':
            # The keepout is x=24..26 across the board, even though tracks can cross it.
            assert max(x for x,y in c)<=24+1e-8 or min(x for x,y in c)>=26-1e-8
    # Area actually fills the safe background, not merely a thin path joining the pads.
    assert any(inside((3.123,3.456),c) for c in cells)
    assert any(inside((46.123,26.456),c) for c in cells)
    # No overlapping cell interiors at a deterministic off-grid sample corpus.
    for ix in range(31):
        for iy in range(19):
            p=(.513+ix*1.59,.317+iy*1.61)
            assert sum(all(cross(a,b,p)>1e-8 for a,b in edges(c)) for c in cells)<=1
    count,connected=groups(cells,bridge=name in ('bridged','redo'))
    assert connected==expected and count==(1 if expected else 2)
    assert len(data['board']['airwires'])==(0 if expected else 1)
    assert doc['past'][-1]['after']==doc['design']
    assert all(a['after']==b['before'] for a,b in zip(doc['past'],doc['past'][1:]))
assert read('zones-undo.ftkc')['design']==read('zones-split.ftkc')['design']
assert read('zones-redo.ftkc')['design']==read('zones-bridged.ftkc')['design']
print('PASS independent zones: cell coverage, board/foreign-net clearance, keepout, physical island connectivity and persistent history')
