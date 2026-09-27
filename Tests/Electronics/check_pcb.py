#!/usr/bin/env python3
"""Independent reader of the physical two-layer fixture: no ElectronicsCore calls."""
import json
import math
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
def read(name):
    return json.loads((root / name).read_text())
def point(p):
    return p['x'], p['y']
def key(k):
    return k['id'], k['revision']
def close(a, b):
    return math.dist(a, b) < 1e-9

doc = read('routed.ftkc')
assert doc['formatVersion'] == 4
for name in ('routed.ftkc', 'without-via.ftkc', 'undo.ftkc', 'redo.ftkc'):
    f = read(name)
    assert f['past'][-1]['after'] == f['design']
    assert all(a['after'] == b['before'] for a,b in zip(f['past'], f['past'][1:]))
    if f['future']:
        assert f['future'][-1]['before'] == f['design']
design = doc['design']
copper = design['board']['copper']
assert copper['layerCount'] == 2
assert len(copper['tracks']) == 2 and len(copper['vias']) == 1
tracks = sorted(copper['tracks'], key=lambda t: t['layer'])
via = copper['vias'][0]
assert [t['layer'] for t in tracks] == [0,1]
assert all(t['netID'] == via['netID'] for t in tracks)
assert all(t['width'] >= copper['rules']['minimumTrackWidth'] for t in tracks)
assert via['drill'] >= copper['rules']['minimumDrill']
assert (via['diameter'] - via['drill']) / 2 >= copper['rules']['minimumAnnularRing'] - 1e-9
# Reconstruct pad coordinates from footprints and placements independently.
lib = design['library']
components = {c['id']:c for c in design['components']}
devices = {key(d['key']):d for d in lib['devices']}
footprints = {key(f['key']):f for f in lib['footprints']}
connections = {(c['pin']['componentID'],c['pin']['pinID']):c.get('netID') for c in design['connections']}
terminals = []
for placed in design['board']['placements']:
    cid = placed['componentID']; device = devices[key(components[cid]['device'])]
    pin_for_pad = {m['padID']:m['pinID'] for m in device['pinMap']}
    theta = math.radians(placed['rotationDegrees'])
    for pad in footprints[key(device['footprint'])]['pads']:
        x,y = point(pad['center'])
        if placed['side'] == 'bottom': x = -x
        px = placed['position']['x'] + math.cos(theta)*x - math.sin(theta)*y
        py = placed['position']['y'] + math.sin(theta)*x + math.cos(theta)*y
        if connections.get((cid,pin_for_pad[pad['id']])) == via['netID']:
            terminals.append(((px,py),0 if placed['side'] == 'top' else 1))
assert len(terminals) == 2
# The known fixture consists of two straight tracks that only meet at a via.
# Same XY on disjoint copper layers alone is insufficient for physical continuity.
for pos,layer in terminals:
    t = tracks[layer]
    assert len(t['points']) == 2
    assert any(close(point(p),pos) for p in t['points'])
    assert any(close(point(p),point(via['position'])) for p in t['points'])
assert read('without-via.ftkc')['design']['board']['copper']['vias'] == []
assert len(read('without-via-board.json')['airwires']) == 1
snapshot = read('routed-snapshot.json')
assert snapshot['board']['airwires'] == []
assert not any(i['severity'] == 'error' for i in snapshot['issues'])
assert read('undo.ftkc')['design'] == read('without-via.ftkc')['design']
assert read('redo.ftkc')['design'] == design
# Independently establish the deliberate perpendicular short from its coordinates.
bad = read('collision-preview.json')['board']['copper']['tracks'][-1]
a,b = map(point,bad['points']); c,d = map(point,tracks[0]['points'])
assert a[0] == b[0] and c[1] == d[1]
assert min(c[0],d[0]) < a[0] < max(c[0],d[0])
assert min(a[1],b[1]) < c[1] < max(a[1],b[1])
assert bad['layer'] == tracks[0]['layer'] and bad['netID'] != tracks[0]['netID']
assert any(i['code'] == 'pcb_short' and bad['id'] in i['subjectIDs'] for i in read('collision-issues.json'))
assert bad['id'] not in {t['id'] for t in copper['tracks']}
print('PASS independent PCB reader: pad transforms, layer continuity, via drill/ring, short geometry, atomic history.')
