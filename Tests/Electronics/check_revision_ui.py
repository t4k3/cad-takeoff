#!/usr/bin/env python3
"""Prepare synthetic native-UI import data, or independently check a saved UI result.

prepare BINARY FRESH_DIRECTORY
check DIRECTORY SAVED_DOCUMENT [imported|undone|redone|unchanged]
No project or source fixture is overwritten. No UI or Swift model is driven here.
"""
import copy
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import uuid

repo = Path(__file__).resolve().parents[2]


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    with Path(path).open('x') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)


def prepare(binary, root):
    if not binary.is_file():
        raise FileNotFoundError(f'Build electronics-library first; binary not found: {binary}')
    root.mkdir(parents=True, exist_ok=False)
    (root / 'QA_Shapes.kicad_mod').write_text('''(footprint "QA_Shapes" (layer "F.Cu")
      (pad "1" smd rect (at -8 0 45) (size 4 2) (layers "F.Cu" "F.Paste" "F.Mask"))
      (pad "2" smd oval (at -3 0 30) (size 4 2) (layers "F.Cu" "F.Paste" "F.Mask"))
      (pad "3" smd roundrect (at 3 0 15) (size 4 2) (roundrect_rratio 0.1) (layers "F.Cu" "F.Paste" "F.Mask"))
      (pad "4" thru_hole circle (at 8 0 45) (size 2 2) (drill 0.8) (layers "*.Cu" "*.Mask")))''')
    corpus = repo / 'Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures'
    name = 'QA_Revision_R0603.kicad_mod'
    # Same documented adapter identity used by CircuitModel: filename|stem, SHA256 UUID.
    data = bytearray(hashlib.sha256(f'{name}|{Path(name).stem}'.encode()).digest()[:16])
    data[6] = (data[6] & 0x0F) | 0x50
    data[8] = (data[8] & 0x3F) | 0x80
    identity = str(uuid.UUID(bytes=bytes(data))).upper()
    source = (corpus / 'Library/R_0603_1608Metric.kicad_mod').read_text()
    bundles = []
    for revision in (1, 2):
        folder = root / f'v{revision}'
        folder.mkdir()
        path = folder / name
        path.write_text(source if revision == 1 else source.replace('0.825', '0.925'))
        context = folder / 'context.json'
        write(context, {
            'key': {'id': identity, 'revision': revision},
            'source': {'reference': str(path), 'license': 'See pinned KiCad corpus license',
                       'sourceRevision': 'Synthetic UI QA revision'},
            'assemblyCentroid': {'x': 0, 'y': 0},
        })
        bundle = folder / 'bundle.json'
        subprocess.run([str(binary), 'kicad-footprint', str(path), str(context), str(bundle)], check=True)
        bundles.append(read(bundle))
    document = read(corpus / 'assembly.json')
    document['design']['name'] = 'QA revisioni libreria - dati sintetici'
    footprint = bundles[0]['library']['footprints'][0]
    library = document['design']['library']
    library['footprints'].append(footprint)
    device = library['devices'][0]
    old_footprint = next(f for f in library['footprints'] if f['key'] == device['footprint'])
    numbers = {pad['id']: pad['number'] for pad in old_footprint['pads']}
    ids = {pad['number']: pad['id'] for pad in footprint['pads']}
    device['footprint'] = footprint['key']
    for mapping in device['pinMap']:
        mapping['padID'] = ids[numbers[mapping['padID']]]
    initial = root / '01-iniziale.ftkc'
    write(root / '00-baseline.json', document)
    write(initial, document)
    subprocess.run([str(binary), 'preview-import', str(initial), str(root / 'v2/bundle.json'), '0',
                    str(root / 'expected-preview.json')], check=True)
    preview = read(root / 'expected-preview.json')
    affected = preview['revisionDiffs'][0]['affectedComponentIDs']
    assert len(affected) == 5  # R1-R5 use this revision; R6 uses the separate device.
    write(root / 'manifest.json', {'libraryID': identity, 'affectedIDs': affected})
    print(f'PASS QA fixture: {initial}; changed footprint in v2/{name}; affected R1-R5, R6 unchanged.')


def check(root, saved, mode):
    initial = read(root / '00-baseline.json')
    actual = read(saved)
    baseline = initial['design']
    identity = read(root / 'manifest.json')['libraryID']
    assert actual['formatVersion'] == 9
    if mode in ('unchanged', 'undone'):
        assert actual['design'] == baseline
        if mode == 'unchanged':
            assert actual['past'] == actual['future'] == [] and actual['revision'] == 0
        else:
            assert actual['past'] == [] and len(actual['future']) == 1 and actual['revision'] == 2
    else:
        assert mode in ('imported', 'redone')
        assert actual['revision'] == (1 if mode == 'imported' else 3)
        assert len(actual['past']) == 1 and actual['future'] == []
        assert actual['past'][0]['before'] == baseline
        assert actual['past'][0]['after'] == actual['design']
        normalized = copy.deepcopy(actual['design'])
        footprints = normalized['library']['footprints']
        added = [f for f in footprints if f['key'] == {'id': identity, 'revision': 2}]
        assert len(added) == 1
        previous = next(f for f in baseline['library']['footprints'] if f['key']['id'] == identity)
        assert {p['id'] for p in added[0]['pads']} == {p['id'] for p in previous['pads']}
        assert all(math.isclose(abs(p['center']['x']), 0.925) for p in added[0]['pads'])
        footprints.remove(added[0])
        assert normalized == baseline  # Components, nets, board and all prior definitions preserved.
    print(f'PASS saved document ({mode}): revision {actual["revision"]}, pinned components and history verified.')


if sys.argv[1:2] == ['prepare'] and len(sys.argv) == 4:
    prepare(Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
elif sys.argv[1:2] == ['check'] and len(sys.argv) in (4, 5):
    check(Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), sys.argv[4] if len(sys.argv) == 5 else 'imported')
else:
    sys.exit(__doc__)
