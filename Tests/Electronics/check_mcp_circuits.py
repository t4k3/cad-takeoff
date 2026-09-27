#!/usr/bin/env python3
"""Live local MCP acceptance, ONLY on the disposable T104 fixture.
No credential is printed or copied into the evidence. Does not save the document.
Usage: check_mcp_circuits.py DISCOVERY_JSON NEW_EVIDENCE_DIRECTORY
   or: check_mcp_circuits.py --bridge SIGNED_APP/Contents/MacOS/ftk-mcp NEW_EVIDENCE_DIRECTORY
"""
import argparse
import atexit
import json
from pathlib import Path
import selectors
import subprocess
import urllib.parse
import urllib.request

EXPECTED_ID='fab00000-0000-0000-0000-000000001104'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bridge',action='store_true',help='Use the app signed stdio/HTTP bridge without reading its protected credentials')
parser.add_argument('connection',type=Path)
parser.add_argument('output',type=Path)
args=parser.parse_args()
output=args.output; output.mkdir(parents=True,exist_ok=False)
bridge=None
if args.bridge:
    assert args.connection.name=='ftk-mcp' and args.connection.parent.name=='MacOS', 'Use the bridge shipped inside the app'
    bridge=subprocess.Popen([str(args.connection.resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    def close_bridge():
        bridge.stdin.close()
        try: bridge.wait(timeout=3)
        except subprocess.TimeoutExpired:
            bridge.terminate(); bridge.wait(timeout=3)
    atexit.register(close_bridge)
    readable=selectors.DefaultSelector(); readable.register(bridge.stdout,selectors.EVENT_READ)
else:
    discovery=json.loads(args.connection.read_text())
    address=urllib.parse.urlparse(discovery['url'])
    assert address.scheme=='http' and address.hostname=='127.0.0.1' and address.path=='/mcp', 'Local app discovery required'
transcript=[]
request_id=0
def rpc(method,params):
    global request_id
    request_id+=1
    body=dict(jsonrpc='2.0',id=request_id,method=method,params=params)
    if bridge:
        bridge.stdin.write(json.dumps(body)+'\n'); bridge.stdin.flush()
        assert readable.select(timeout=30),'MCP bridge response timed out'
        value=json.loads(bridge.stdout.readline())
    else:
        request=urllib.request.Request(discovery['url'],data=json.dumps(body).encode(),headers={
            'Content-Type':'application/json','Authorization':'Bearer '+discovery['token']})
        with urllib.request.urlopen(request,timeout=30) as response: value=json.load(response)
    transcript.append(dict(request=body,response=value))
    (output/'calls.json').write_text(json.dumps(transcript,indent=2,ensure_ascii=False))
    assert 'error' not in value,value
    return value['result']
def call(name,args=None,error=False):
    result=rpc('tools/call',dict(name=name,arguments=args or {}))
    assert result.get('isError',False)==error,(name,result)
    return result.get('structuredContent',{})
def info():
    value=call('circuit_info')
    assert value['design_id'].lower()==EXPECTED_ID,'Refusing to touch a different document'
    assert value['name'].startswith('QA Produzione'), 'Disposable fixture required'
    return value
def nets(value): return [(v['id'],v['name']) for v in value['nets']]
def preview(args,token):
    return call('circuit_preview',dict(**args,expected_revision=token))
def apply(p,token):
    return call('circuit_apply',dict(preview_id=p['preview_id'],expected_revision=token))

hello=rpc('initialize',dict(protocolVersion='2025-11-25',capabilities={},clientInfo=dict(name='Codex T104 isolated QA',version='1')))
catalog=rpc('tools/list',{})['tools']
names={t['name'] for t in catalog}
assert {'circuit_info','circuit_issues','circuit_library','circuit_pins','circuit_preview','circuit_apply','circuit_undo','circuit_redo','circuit_fabrication_check'}<=names
first=info(); token=first['revision']; original_nets=nets(first)
assert first['document_revision']==0 and not first['modified'], 'Open a fresh 01-produzione.ftkc copy first'
check=call('circuit_fabrication_check')
assert check['can_export'] and len(check['layers'])==9 and check['holes']==3
assert info()['revision']==token
for args in [dict(solder_mask_expansion='wrong'),dict(tent_vias='false'),dict(paste_inset=True)]:
    call('circuit_fabrication_check',args,error=True)
call('circuit_preview',dict(action='add_track',net='SUPPLY',points=[dict(x=5,y=15),dict(x=13.5,y=15)],layer=123,expected_revision=token),error=True)
call('circuit_preview',dict(action='rename_net',net='SUPPLY',name='QA_WRONG',component='R1',expected_revision=token),error=True)
assert info()['revision']==token

# A no-op is never a new assistant-owned undo step.
p=preview(dict(action='rename_net',net='SUPPLY',name='SUPPLY'),token)
assert p['can_apply'] and info()['revision']==token
unchanged=apply(p,token)
assert not unchanged['changed'] and not unchanged['can_undo'] and info()['revision']==token

# Keep one preview to try confirming it after the document has changed.
stale=preview(dict(action='rename_net',net='LED',name='QA_STALE'),token)
a=preview(dict(action='rename_net',net='SUPPLY',name='QA_SUPPLY_1'),token)
assert info()['revision']==token and nets(info())==original_nets
ra=apply(a,token); assert ra['changed'] and ra['can_undo']
call('circuit_apply',dict(preview_id=stale['preview_id'],expected_revision=token),error=True)
call('circuit_apply',dict(preview_id=stale['preview_id'],expected_revision=ra['revision']),error=True)
b=preview(dict(action='rename_net',net='QA_SUPPLY_1',name='QA_SUPPLY_2'),ra['revision'])
rb=apply(b,ra['revision']); assert rb['changed']
ub=call('circuit_undo',dict(expected_revision=rb['revision'])); assert ub['can_undo'] and ub['can_redo']
assert any(n['name']=='QA_SUPPLY_1' for n in info()['nets'])
ua=call('circuit_undo',dict(expected_revision=ub['revision'])); assert nets(info())==original_nets
assert not ua['can_undo'] and ua['can_redo']
redo_a=call('circuit_redo',dict(expected_revision=ua['revision'])); assert redo_a['can_redo']
redo_b=call('circuit_redo',dict(expected_revision=redo_a['revision']))
assert any(n['name']=='QA_SUPPLY_2' for n in info()['nets'])
undo_b=call('circuit_undo',dict(expected_revision=redo_b['revision']))
undo_a=call('circuit_undo',dict(expected_revision=undo_b['revision']))
assert nets(info())==original_nets

# A new short is visible in preview and cannot be applied.
token=info()['revision']
bad=preview(dict(action='add_track',net='SUPPLY',points=[dict(x=5,y=15),dict(x=16.5,y=15)],layer='top',width=.4),token)
assert not bad['can_apply'] and any(i['code']=='pcb_short' for i in bad['blocking_issues'])
call('circuit_apply',dict(preview_id=bad['preview_id'],expected_revision=token),error=True)
assert info()['revision']==token

# Valid copper goes through the real worker; undo restores its count.
before=info()
good=preview(dict(action='add_track',net='SUPPLY',points=[dict(x=6,y=15),dict(x=12,y=15)],layer='top',width=.3),token)
assert good['can_apply']
done=apply(good,token)
assert len(info()['tracks'])==len(before['tracks'])+1
call('circuit_undo',dict(expected_revision=done['revision']))

# Build a small logical circuit using only advertised devices and pin names.
# Preview and apply must retain the new component's identity; undo restores the fixture.
devices=call('circuit_library')['devices']
resistor=next(d for d in devices if d['reference_prefix']=='R' and len(d['pins'])==2)
for reference,x in [('R91',28),('R92',33)]:
    token=info()['revision']
    p=preview(dict(action='add_component',device=resistor['device'],reference=reference,value='QA 4k7',x=x,y=24),token)
    assert p['can_apply'] and not any(c['reference']==reference for c in info()['components'])
    assert apply(p,token)['changed']
    component=next(c for c in info()['components'] if c['reference']==reference)
    assert component['x']==x and component['y']==24 and component['value']=='QA 4k7'
pins91=call('circuit_pins',dict(component='R91'))['pins']
pins92=call('circuit_pins',dict(component='R92'))['pins']
assert len(pins91)==len(pins92)==2 and all(p['net'] is None for p in pins91+pins92)
join=[pins91[1]['pin'],pins92[0]['pin']]
for action in [dict(action='connect',pins=join,net='QA_LINK'),
               dict(action='no_connect',pins=[pins92[1]['pin']]),
               dict(action='disconnect',pins=[pins91[1]['pin']])]:
    token=info()['revision']
    p=preview(action,token); assert p['can_apply']
    assert apply(p,token)['changed']
    if action['action']=='connect':
        assert call('circuit_pins',dict(component='R91'))['pins'][1]['net']=='QA_LINK'
        assert call('circuit_pins',dict(component='R92'))['pins'][0]['net']=='QA_LINK'
    elif action['action']=='no_connect':
        assert call('circuit_pins',dict(component='R92'))['pins'][1]['no_connect']
    else:
        assert call('circuit_pins',dict(component='R91'))['pins'][1]['net'] is None
for _ in range(5):
    call('circuit_undo',dict(expected_revision=info()['revision']))
last=info()
assert last['tracks']==first['tracks'] and last['components']==first['components'] and nets(last)==original_nets
assert call('circuit_fabrication_check')['can_export']
summary=dict(result='PASS',transport='signed stdio bridge to local HTTP' if bridge else 'local HTTP',server=hello['serverInfo'],calls=len(transcript),tools=sorted(n for n in names if n.startswith('circuit_')),
    designID=EXPECTED_ID,initialRevision=first['document_revision'],finalRevision=last['document_revision'],
    checks=['read-only preflight','strict argument types','no-op','preview/apply','stale tokens','two consecutive undo/redo',
            'new short blocked','copper worker','library and pins','add components','connect/disconnect/NC','geometry restored'],
    limits=['local HTTP MCP only; no remote AI provider call','document not saved; in-memory history contains QA steps'])
(output/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False))
print('PASS local MCP Circuiti:',len(transcript),'calls; geometry restored; no document saved.')
