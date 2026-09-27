#!/usr/bin/env python3
"""Create disposable app/MCP acceptance copies; never rewrite an existing QA directory."""
import copy
import json
from pathlib import Path
import sys

root=Path(__file__).resolve().parents[2]
target=Path(sys.argv[1])
source=root/'Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/fabrication.json'
base=json.loads(source.read_text())
base['design']['name']='QA Produzione — componenti sintetici NON qualificati'
base['design']['id']='FAB00000-0000-0000-0000-000000001104'
base['design']['variants']=[dict(id='FAB00000-0000-0000-0000-000000001105',name='Senza D1',excludedComponents=[base['design']['components'][2]['id']])]
target.mkdir(parents=True,exist_ok=False)
def write(name,value): (target/name).write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')
write('01-produzione.ftkc',base)
broken=copy.deepcopy(base)
broken['design']['name']='QA Produzione bloccata — pista mancante'
broken['design']['id']='FAB00000-0000-0000-0000-000000001106'
broken['design']['board']['copper']['tracks'].pop(0)
write('02-pista-mancante.ftkc',broken)
# Same design/revision but a different file: the app must invalidate old work using its epoch.
reopened=copy.deepcopy(base)
reopened['design']['name']='QA stessa identità — D1 non montato'
reopened['design']['components'][2]['assembly']='doNotPopulate'
write('03-stessa-identita-dnp.ftkc',reopened)
write('acceptance.json',dict(source=str(source),designID=base['design']['id'],revision=base['revision'],
    variantID=base['design']['variants'][0]['id'],components={c['reference']:c['id'] for c in base['design']['components']},
    expected=dict(files=17,layers=9,holes=3,past=0,future=0)))
print(target.resolve())
