#!/usr/bin/env python3
"""Independent analytical checks on exported copper, using only Python's standard library.
Does not call Swift geometry or trust its reported spoke count/connectivity alone.
"""
import json
import math
import sys
from pathlib import Path

root = Path(sys.argv[1])
def read(name): return json.loads((root / name).read_text())
def point(p): return p['x'], p['y']
def edges(p): return list(zip(p, p[1:]+p[:1]))
def cross(a,b,p): return (b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0])
def inside(p,c): return all(cross(a,b,p)>=-1e-9 for a,b in edges(c))
def area(c): return sum(a[0]*b[1]-a[1]*b[0] for a,b in edges(c))/2
def cells(data): return [[point(p) for p in c] for c in data['zones'][0]['cells']]
def contains(polygons,p): return any(inside(p,c) for c in polygons)
def dist(p,a,b):
    dx,dy=b[0]-a[0],b[1]-a[1]
    t=max(0,min(1,((p[0]-a[0])*dx+(p[1]-a[1])*dy)/(dx*dx+dy*dy)))
    return math.hypot(p[0]-a[0]-t*dx,p[1]-a[1]-t*dy)

for name in ('solid','connected','filtered','starved','undo','redo','isolated'):
    data=read(f'thermals-{name}.json'); doc=read(f'thermals-{name}.ftkc')
    polygons=cells(data); zone=data['zones'][0]
    assert doc['formatVersion']==7 and all(area(c)>0 for c in polygons)
    assert abs(sum(map(area,polygons))-zone['area'])<1e-7
    assert all(a['after']==b['before'] for a,b in zip(doc['past'],doc['past'][1:]))
    assert doc['past'][-1]['after']==doc['design']
    # All cell vertices respect the original outline and the foreign track capsule.
    # Track width .5 plus default clearance .2 => exclusion radius .45 mm.
    for c in polygons:
        for x,y in c:
            assert 1-1e-8<=x<=49+1e-8 and 1-1e-8<=y<=29+1e-8
            assert dist((x,y),(12,15),(38,15))>=.45-1e-8
        assert not inside((25,15),c)
    thermal=name not in ('solid','isolated')
    damaged=name in ('starved','redo')
    pads=[p for p in data['board']['pads'] if p.get('netID','').endswith('000000000010')]
    assert len(pads)==4
    for pad in pads:
        px,py=point(pad['center']); hx,hy=pad['size']['x']/2,pad['size']['y']/2
        if thermal:
            counted=0
            for dx,dy in ((1,0),(0,1),(-1,0),(0,-1)):
                half=hx if dx else hy
                # Full-width ray coverage: sample 21 x 19 interior points across each
                # straight thermal bridge, including the off-centre keepout interruption.
                intact=all(contains(polygons,(px+dx*(half+.015+i*.02)-dy*s,
                                               py+dy*(half+.015+i*.02)+dx*s))
                           for i in range(21) for s in (j*.02 for j in range(-9,10)))
                counted+=intact
            expected=3 if damaged and pad['componentID'].endswith('000000000001') else 4
            assert counted==expected,(name,pad['componentID'],counted)
            report=next(t for t in zone['thermals'] if t['padID']==pad['padID'] and t['componentID']==pad['componentID'])
            assert report['connectedSpokes']==counted
            # Analytic rounded pad: diagonal point outside the pad, inside .4 mm gap,
            # and outside both .4 mm spokes must have no copper.
            assert not contains(polygons,(px+hx+.08,py+hy+.08))
        elif name=='isolated':
            for dx,dy in ((1,0),(0,1),(-1,0),(0,-1)):
                half=hx if dx else hy
                assert not contains(polygons,(px+dx*(half+.2),py+dy*(half+.2)))
    assert len(data['board']['airwires'])==(3 if name=='isolated' else 0)
    assert any(i['code']=='pcb_thermal_starved' for i in data['issues'])==damaged
    if name in ('starved','redo','isolated'):
        # Even where pad copper would connect around it, this precise keepout stays void.
        assert not contains(polygons,(9.325,8.075))
    assert contains(polygons,(3.123,3.456)) and contains(polygons,(46.123,26.456))
    for ix in range(17):
        for iy in range(13):
            p=(1.071+ix*2.93,1.019+iy*2.29)
            assert sum(all(cross(a,b,p)>1e-8 for a,b in edges(c)) for c in polygons)<=1
assert read('thermals-undo.ftkc')['design']==read('thermals-filtered.ftkc')['design']
assert read('thermals-redo.ftkc')['design']==read('thermals-starved.ftkc')['design']
assert read('thermals-filtered.json')['zones'][0]['removedNarrowArea']>0

dense=read('thermals-dense.json'); dense_cells=cells(dense)
dense_pads=[p for p in dense['board']['pads'] if p.get('netID','').endswith('000000000010')]
assert len(dense_pads)==16 and len(dense['board']['airwires'])==0
for pad in dense_pads:
    px,py=point(pad['center'])
    for dx,dy in ((1,0),(0,1),(-1,0),(0,-1)):
        half=pad['size']['x' if dx else 'y']/2
        assert all(contains(dense_cells,(px+dx*(half+t)-dy*s,py+dy*(half+t)+dx*s))
                   for t in (.02,.1,.2,.3,.41) for s in (-.18,0,.18))
    assert not contains(dense_cells,(px+pad['size']['x']/2+.08,py+pad['size']['y']/2+.08))

for name in ('raw','narrow','wide','pinch'):
    data=read(f'width-{name}.json'); polygons=cells(data)
    bridge=all(contains(polygons,(15.01+i*.1,15)) for i in range(200))
    if name=='narrow':
        assert not bridge and not contains(polygons,(25,15))
        assert data['zones'][0]['islandCount']==2 and data['zones'][0]['removedNarrowArea']>7
    elif name=='pinch':
        # A short .8 mm throat cannot be approved for a 1 mm path even if the opening
        # operation regrows a connected patch. A surviving connection must be diagnosed.
        assert not bridge or any(i['code']=='pcb_zone_neck' for i in data['issues'])
    else:
        assert bridge and data['zones'][0]['islandCount']==1
        assert not any(i['code']=='pcb_zone_neck' for i in data['issues'])
    assert contains(polygons,(5,15)) and contains(polygons,(45,15))
print('PASS independent thermals: physical full-width spokes, partial starvation, clearance, isolation, width filtering, neck diagnostics and persistent history')
