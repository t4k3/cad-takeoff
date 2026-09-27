#!/usr/bin/env python3
"""Independent topology, history and geometry reader for the Swift-generated schema fixtures."""
import json
import math
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def terminal(encoded):
    if 'pin' in encoded:
        pin = encoded['pin']['_0']
        return ('pin', pin['componentID'], pin['pinID'])
    return ('junction', encoded['junction']['_0'])

def check_document(name, expected_nets):
    doc = json.loads((root / name).read_text())
    assert doc['formatVersion'] == 4
    design = doc['design']
    schema = design['schematic']
    parent = {}
    def find(t):
        parent.setdefault(t, t)
        if parent[t] != t:
            parent[t] = find(parent[t])
        return parent[t]
    wires = [wire for sheet in schema['sheets'] for wire in sheet['wires']]
    for wire in wires:
        a, b = terminal(wire['start']), terminal(wire['end'])
        parent[find(a)] = find(b)
    groups = {}
    for t in list(parent):
        groups.setdefault(find(t), set()).add(t)
    assert len(groups) == expected_nets, (name, groups)
    nets = {(c['pin']['componentID'], c['pin']['pinID']): c.get('netID') for c in design['connections']}
    wire_nets = {w['wireID']: w['netID'] for w in schema['wireNets']}
    assert len(nets) == 4
    group_nets = []
    for group in groups.values():
        ids = {nets[t[1:]] for t in group if t[0] == 'pin'}
        assert len(ids) == 1 and None not in ids
        group_nets.append(next(iter(ids)))
    assert len(set(group_nets)) == expected_nets, 'Disconnected islands must not share an automatic net'
    assert {n['id'] for n in design['nets']} == set(group_nets)
    for wire in wires:
        for endpoint in ('start', 'end'):
            t = terminal(wire[endpoint])
            assert wire_nets[wire['id']] == nets[t[1:]]
    history = doc['past']
    assert history[-1]['after'] == design
    for a, b in zip(history, history[1:]):
        assert a['after'] == b['before']
    assert all(step['before']['id'] == design['id'] == step['after']['id'] for step in history)
    return doc

joined = check_document('joined.ftkc', 1)
split = check_document('split.ftkc', 2)
transformed = check_document('transformed.ftkc', 2)
assert joined['design']['board'] == split['design']['board'] == transformed['design']['board']
assert split['design']['connections'] == transformed['design']['connections']
assert transformed['past'][-1]['before'] == split['design']

# Recompute all transformed pin endpoints without Swift's geometry helpers.
design = transformed['design']
components = {c['id']: c for c in design['components']}
def key(k): return k['id'], k['revision']
devices = {key(d['key']): d for d in design['library']['devices']}
symbols = {key(s['key']): s for s in design['library']['symbols']}
expected = {}
for sheet in design['schematic']['sheets']:
    for placed in sheet['symbols']:
        cid = placed['componentID']
        definition = symbols[key(devices[key(components[cid]['device'])]['symbol'])]
        angle = math.radians(placed['rotationDegrees'])
        for pin in definition['pins']:
            x = pin['position']['x'] * (-1 if placed['mirrored'] else 1)
            y = pin['position']['y']
            expected[cid, pin['id']] = (
                placed['position']['x'] + math.cos(angle) * x - math.sin(angle) * y,
                placed['position']['y'] + math.sin(angle) * x + math.cos(angle) * y,
            )
actual = json.loads((root / 'pins.json').read_text())
assert len(expected) == len(actual) == 8
for pin in actual:
    x, y = expected[pin['componentID'], pin['pinID']]
    assert math.isclose(pin['position']['x'], x, abs_tol=1e-9)
    assert math.isclose(pin['position']['y'], y, abs_tol=1e-9)

metrics = json.loads((root / 'metrics.json').read_text())
assert metrics['components'] == 1000 and metrics['queryCount'] == 1000
assert all(math.isfinite(metrics[k]) and metrics[k] >= 0 for k in ('snapshotMS', 'pickSnapP95MS', 'pickSnapMaxMS'))
print('PASS: independent schema graph, split nets, shared PCB identities, history and transformed pin endpoints')
print('Metrics (not a hard CI timing threshold):', metrics)
