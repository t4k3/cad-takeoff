#!/usr/bin/env python3
"""Independent standard-library reader for the native ZIP/BOM/CPL import.

No private production input is stored in the repository. Optional real-file mode:
check_manufacturing.py BINARY NEW_DIRECTORY ZIP BOM CPL
"""
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

binary = str(Path(sys.argv[1]).resolve())
root = Path(sys.argv[2]).resolve()
root.mkdir(parents=True, exist_ok=False)

def run(archive, bom, cpl, output, good=True):
    args = [binary, str(archive), str(bom), str(cpl), str(output), 'QA Import', 'Lotto A']
    result = subprocess.run(args, capture_output=True, text=True)
    assert (result.returncode == 0) == good, result.stdout + result.stderr
    return result

def load(path):
    doc = json.loads(path.read_text())
    assert doc['formatVersion'] == 9 and doc['revision'] == 1
    assert len(doc['past']) == 1 and not doc['future']
    assert doc['past'][0]['after'] == doc['design']
    assert doc['past'][0]['before'].get('manufacturing') is None
    assert not doc['design']['components']  # no fictional native footprints/symbols
    package = doc['design']['manufacturing'].copy()
    if 'geometryID' in package:
        geometry = doc['manufacturingGeometry'][package.pop('geometryID')]
        package.update(geometry)
    return package

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def assert_tables(package, bom, cpl):
    with bom.open(encoding='utf-8-sig', newline='') as f:
        entries = list(csv.DictReader(f))
    with cpl.open(encoding='utf-8-sig', newline='') as f:
        positions = list(csv.DictReader(f))
    refs = {r.strip(): row for row in entries for r in row['Designator'].split(',')}
    components = {c['reference']: c for c in package['components']}
    lot = next(l for l in package['lots'] if l['id'] == package['activeLotID'])
    fitted = set(lot['fittedComponentIDs'])
    assert len(fitted) == len(refs)
    for ref, row in refs.items():
        c = components[ref]
        assert c['id'] in fitted and c['value'] == row['Value'] and c['footprint'] == row['Footprint']
        assert c.get('lcscPartNumber', '') == row['LCSC Part #']
    for row in positions:
        c = components[row['Designator']]
        p = c['placement']
        assert p['position'] == {'x': float(row['Mid X']), 'y': float(row['Mid Y'])}
        assert p['rotationDegrees'] == float(row['Rotation']) and p['side'] == row['Layer']
    assert all((c['id'] in fitted) == (ref in refs) for ref, c in components.items())
    return components

if len(sys.argv) == 6:
    archive, bom, cpl = map(Path, sys.argv[3:])
    originals = list(map(digest, [archive, bom, cpl]))
    print(run(archive, bom, cpl, root / 'import.ftkc').stdout)
    p = load(root / 'import.ftkc')
    components = assert_tables(p, bom, cpl)
    assert len(p['layers']) == 9
    assert p['bounds'] == {'minimum': {'x': 100, 'y': -151}, 'maximum': {'x': 165, 'y': -70}}
    assert len(p['drills']) == 158
    assert sum('end' in d for d in p['drills']) == 4
    assert sum(not d['isPlated'] for d in p['drills']) == 4
    assert len(components) == 86 and components['IC2'].get('placement') is None
    assert len({o['netName'] for l in p['layers'] for o in l['primitives'] if o.get('netName')}) >= 80
    assert originals == list(map(digest, [archive, bom, cpl]))
    print('PASS real Ballgun: 86 references, 84 fitted, 158 drills including 4 slots; original bytes unchanged.')
else:
    def gerber(function, content):
        return f'%TF.FileFunction,{function}*%\n%FSLAX46Y46*%\n%MOMM*%\n%ADD10C,0.2*%\nD10*\n{content}\nM02*\n'
    archive, bom, cpl = root / 'board.zip', root / 'bom.csv', root / 'positions.csv'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr('board.gm1', gerber('Profile,NP', 'X100000000Y-70000000D02*\nX165000000Y-70000000D01*\nX165000000Y-151000000D01*\nX100000000Y-151000000D01*\nX100000000Y-70000000D01*'))
        z.writestr('board.gtl', gerber('Copper,L1,Top', '%TO.N,GND*%\n%TO.P,R1,1*%\nX120000000Y-80000000D03*\n%TO.P,IC2,1*%\nX140000000Y-90000000D03*'))
        z.writestr('board.gbl', gerber('Copper,L2,Bot', 'X140000000Y-90000000D03*'))
        z.writestr('board-NPTH.drl', 'M48\nMETRIC\nT1C3.2\n%\nG90\nT1\nX104.0Y-74.0\nM30\n')
    bom.write_text('Designator,Footprint,Quantity,Value,LCSC Part #\nR1,R0805,1,10k,C123\nJ8,Header,1,Boot,\n')
    cpl.write_text('Designator,Mid X,Mid Y,Rotation,Layer\nR1,120,-80,90,top\nJ8,154.495,-71.99,90,top\nT1,148.455,-82.81,0,bottom\n')
    originals = list(map(digest, [archive, bom, cpl]))
    run(archive, bom, cpl, root / 'one.ftkc')
    p = load(root / 'one.ftkc'); components = assert_tables(p, bom, cpl)
    assert set(components) == {'R1', 'J8', 'IC2', 'T1'}
    assert len(p['drills']) == 1 and not p['drills'][0]['isPlated']
    assert p['bounds'] == {'minimum': {'x': 100, 'y': -151}, 'maximum': {'x': 165, 'y': -70}}
    assert any(o.get('componentReference') == 'IC2' and o.get('pinNumber') == '1' and o.get('netName') == 'GND'
               for l in p['layers'] for o in l['primitives'])
    run(archive, bom, cpl, root / 'two.ftkc')
    assert p == load(root / 'two.ftkc'), 'stable identities across identical imports'
    saved = digest(root / 'one.ftkc')
    run(archive, bom, cpl, root / 'one.ftkc', good=False)
    assert saved == digest(root / 'one.ftkc'), 'never overwrite'
    bad = root / 'bad-bom.csv'; bad.write_text(bom.read_text().replace('R1,R0805,1', 'R1,R0805,2'))
    run(archive, bad, cpl, root / 'bad.ftkc', good=False)
    assert not (root / 'bad.ftkc').exists()
    # Unrecognized production files must never disappear silently.
    unknown = root / 'unknown.zip'
    with zipfile.ZipFile(archive) as source, zipfile.ZipFile(unknown, 'w', compression=zipfile.ZIP_DEFLATED) as target:
        for name in source.namelist():
            target.writestr(name, source.read(name))
        target.writestr('extra-layer.dat', 'unrecognized manufacturing data')
    run(unknown, bom, cpl, root / 'unknown.ftkc', good=False)
    assert not (root / 'unknown.ftkc').exists()
    # Recognize a drill by explicit content even with a nonstandard filename.
    renamed = root / 'renamed-drill.zip'
    with zipfile.ZipFile(archive) as source, zipfile.ZipFile(renamed, 'w', compression=zipfile.ZIP_DEFLATED) as target:
        for name in source.namelist():
            data = source.read(name)
            if name.endswith('.drl'):
                name = 'holes.txt'
                data = data.replace(b'M48\n', b'M48\n; #@! TF.FileFunction,NonPlated,1,2,NPTH\n')
            target.writestr(name, data)
    run(renamed, bom, cpl, root / 'renamed.ftkc')
    assert len(load(root / 'renamed.ftkc')['drills']) == 1
    dnp = root / 'dnp.csv'
    dnp.write_text('Designator,Footprint,Quantity,Value,LCSC Part #,DNP\nR1,R0805,1,10k,C123,true\nJ8,Header,1,Boot,,false\n')
    run(archive, dnp, cpl, root / 'dnp.ftkc')
    omitted = load(root / 'dnp.ftkc')
    assert omitted['id'] == p['id'] and omitted['layers'] == p['layers']
    selected = set(omitted['lots'][0]['fittedComponentIDs'])
    assert {c['reference'] for c in omitted['components'] if c['id'] in selected} == {'J8'}
    assert {c['reference'] for c in omitted['components']} == set(components)
    assert originals == list(map(digest, [archive, bom, cpl]))
    print('PASS independent manufacturing import: layers, coordinates, metadata, lot omissions, stable IDs, atomic failures.')
