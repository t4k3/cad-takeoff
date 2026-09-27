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
assert doc['formatVersion'] == 5
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

# Second fixture: independently check design constraints and polygon exclusion.
rules_doc = read('rules.ftkc')
assert rules_doc['formatVersion'] == 5
rules_copper = rules_doc['design']['board']['copper']
classes = rules_copper['netClasses']
assert len(classes) == 1 and classes[0]['name'] == 'Potenza'
power = classes[0]
area = rules_copper['keepouts'][0]
assert area['layers'] == [0] and all(area[k] for k in ('tracks','vias','pads'))
assert {point(p) for p in area['outline']} == {(18,8),(22,8),(22,12),(18,12)}
resolved = read('rules-resolved.json')[0]
assert resolved['classID'] == power['id']
assert resolved['rules']['minimumTrackWidth'] == 0.6
assert resolved['routing']['trackWidth'] == 0.6
assert resolved['routing']['viaDrill'] == 0.4
assert math.isclose(resolved['routing']['viaDiameter'], 0.8)
assert len(rules_copper['tracks']) == 3
assert not any(i['severity'] == 'error' for i in read('rules-snapshot.json')['issues'])
assert read('rules-snapshot.json')['keepouts'] == [area]

def projected_distance(p, a, b):
    vx,vy = b[0]-a[0],b[1]-a[1]
    if vx == vy == 0: return math.dist(p,a)
    t = min(1,max(0,((p[0]-a[0])*vx+(p[1]-a[1])*vy)/(vx*vx+vy*vy)))
    return math.dist(p,(a[0]+t*vx,a[1]+t*vy))

def rectangle_distance(a, b):
    # Independent analytic test for this orthogonal fixture, not the Swift DRC.
    if a[1] == b[1]:
        dx = max(18-max(a[0],b[0]),min(a[0],b[0])-22,0)
        dy = max(8-a[1],a[1]-12,0)
    else:
        assert a[0] == b[0]
        dx = max(18-a[0],a[0]-22,0)
        dy = max(8-max(a[1],b[1]),min(a[1],b[1])-12,0)
    return math.hypot(dx,dy)

for t in rules_copper['tracks']:
    if t['netID'] in power['netIDs']: assert t['width'] >= power['constraints']['minimumTrackWidth']
    if t['layer'] in area['layers']:
        vertices = list(map(point,t['points']))
        assert all(rectangle_distance(a,b) > t['width']/2 for a,b in zip(vertices,vertices[1:]))
bottom = next(t for t in rules_copper['tracks'] if t['layer'] == 1)
assert rectangle_distance(*map(point,bottom['points'])) == 0  # allowed only because of layer

for name,code in [('clearance','pcb_clearance'),('width','pcb_track_width'),('keepout','pcb_keepout'),('via','pcb_keepout')]:
    preview = read(f'rule-preview-{name}.json')
    assert preview['canApply'] is False
    assert any(i['code'] == code for i in preview['issues'])
    pc = preview['design']['board']['copper']
    if name == 'clearance':
        t = pc['tracks'][-1]
        gap = projected_distance(point(t['points'][0]),*map(point,pc['tracks'][0]['points'])) - (t['width']+pc['tracks'][0]['width'])/2
        assert gap > rules_copper['rules']['clearance'] and gap < power['constraints']['clearance']
    elif name == 'width':
        assert pc['tracks'][-1]['width'] < power['constraints']['minimumTrackWidth']
    elif name == 'keepout':
        assert rectangle_distance(*map(point,pc['tracks'][-1]['points'])) == 0
    else:
        assert point(pc['vias'][-1]['position']) == (20,10)
    invalid_id = (pc['vias'][-1] if name == 'via' else pc['tracks'][-1])['id']
    assert invalid_id not in {t['id'] for t in rules_copper['tracks']+rules_copper['vias']}
for name in ('rules.ftkc','rules-undo.ftkc','rules-redo.ftkc'):
    item = read(name)
    assert all(a['after'] == b['before'] for a,b in zip(item['past'],item['past'][1:]))
    assert item['past'][-1]['after'] == item['design']
    if item['future']: assert item['future'][-1]['before'] == item['design']
assert len(read('rules-undo.ftkc')['design']['board']['copper']['tracks']) == 1
assert read('rules-redo.ftkc')['design'] == rules_doc['design']
print('PASS independent PCB rules reader: class dimensions, stricter pair clearance, keepout geometry, layers, rejected edits and persistent history.')
