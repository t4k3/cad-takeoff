#!/usr/bin/env python3
"""Independent reader of our emitted Gerber/XNC subset. Python stdlib only.
Checks shapes against the INPUT document, not exporter-generated bounds/counts.
Not a general-purpose Gerber viewer or a manufacturer qualification.
"""
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile

EPS = 3e-6

def distance(a, b): return math.hypot(a[0]-b[0], a[1]-b[1])
def nearest(p, a, b):
    d = (b[0]-a[0], b[1]-a[1]); length = d[0]**2+d[1]**2
    t = max(0, min(1, ((p[0]-a[0])*d[0]+(p[1]-a[1])*d[1])/length)) if length else 0
    return (a[0]+t*d[0], a[1]+t*d[1])
def polygon(p, vertices):
    hit = False
    for a, b in zip(vertices, vertices[1:]+vertices[:1]):
        if distance(p, nearest(p,a,b)) < 1e-9: return True
        if (a[1]>p[1]) != (b[1]>p[1]) and p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]: hit = not hit
    return hit

def translate(shape, x, y):
    k, data = shape
    if k == 'circle': return k, ((data[0][0]+x,data[0][1]+y),data[1])
    if k == 'capsule': return k, ((data[0][0]+x,data[0][1]+y),(data[1][0]+x,data[1][1]+y),data[2])
    return k, [(p[0]+x,p[1]+y) for p in data]

def contains(shape, p):
    kind, data = shape
    if kind == 'circle': return distance(p,data[0]) <= data[1]
    if kind == 'capsule': return distance(p,nearest(p,data[0],data[1])) <= data[2]
    return polygon(p,data)

class Gerber:
    def __init__(self, path):
        text = path.read_text(); self.shapes=[]; self.attrs={}; self.flashes=[]; self.draws=[]; self.regions=[]
        macros={}; tools={}; selected=None; current=None; region=None; unit=False; fmt=False; ended=False
        tokens=re.findall(r'%[^%]*%|[^%*]+\*',text,re.S)
        for raw in tokens:
            t=raw.strip()
            if not t: continue
            if t.startswith('%AM'):
                chunks=t[3:-1].split('*'); name=chunks.pop(0).strip(); shapes=[]
                for line in chunks:
                    if not line.strip(): continue
                    f=[float(x) for x in line.strip().split(',')]; kind=int(f[0]); assert f[1]==1
                    if kind==1:
                        assert f[5]==0; shapes.append(('circle',((f[3],f[4]),f[2]/2)))
                    elif kind==4:
                        n=int(f[2]); assert len(f)==2*n+6 and f[-1]==0
                        pts=list(zip(f[3:-1:2],f[4:-1:2])); assert pts[0]==pts[-1]
                        shapes.append(('polygon',pts[:-1]))
                    elif kind==20:
                        assert len(f)==8 and f[7]==0
                        w=f[2]/2; a=(f[3],f[4]); b=(f[5],f[6]); length=distance(a,b); assert length>0
                        dx=-(b[1]-a[1])*w/length; dy=(b[0]-a[0])*w/length
                        shapes.append(('polygon',[(a[0]+dx,a[1]+dy),(b[0]+dx,b[1]+dy),(b[0]-dx,b[1]-dy),(a[0]-dx,a[1]-dy)]))
                    else: raise AssertionError(('unsupported macro',line))
                macros[name]=shapes
            elif t.startswith('%ADD'):
                m=re.fullmatch(r'%ADD(\d+)([^,*]+)(?:,([^*]+))?\*%',t); assert m,t
                n,name,args=m.groups(); n=int(n); assert n not in tools
                if name=='C': tools[n]=[('circle',((0,0),float(args)/2))]
                else: assert args is None; tools[n]=macros[name]
            elif t.startswith('%TF.'):
                name,value=t[4:-2].split(',',1); self.attrs[name]=value
            elif t=='%FSLAX66Y66*%': fmt=True
            elif t=='%MOMM*%': unit=True
            elif t in ('%LPD*%','G01*'): pass
            elif t.startswith('G04'): pass
            elif t=='G36*': assert region is None; region=[]
            elif t=='G37*':
                assert region and region[0]==region[-1] and len(set(region))>=3
                self.shapes.append(('polygon',region[:-1])); self.regions.append(region[:-1]); region=None
            elif t=='M02*': assert region is None; ended=True
            elif re.fullmatch(r'D\d+\*',t): selected=int(t[1:-1]); assert selected in tools
            else:
                m=re.fullmatch(r'X(-?\d+)Y(-?\d+)D0([123])\*',t); assert m,('unparsed',t)
                assert unit and fmt and not ended
                x,y,op=m.groups(); p=(int(x)/1e6,int(y)/1e6)
                if op=='2':
                    if region is not None: assert not region; region=[p]
                elif op=='3':
                    assert region is None and selected in tools
                    self.flashes.append((p,tools[selected])); self.shapes += [translate(s,*p) for s in tools[selected]]
                elif region is not None: region.append(p)
                else:
                    assert current is not None and selected in tools
                    aperture=tools[selected]; assert len(aperture)==1 and aperture[0][0]=='circle'
                    radius=aperture[0][1][1]; shape=('capsule',(current,p,radius)); self.shapes.append(shape); self.draws.append(shape)
                current=p
        assert unit and fmt and ended and region is None
        assert self.attrs['Part']=='Single'
        assert set(self.attrs) >= {'FileFunction','FilePolarity','SameCoordinates'}
    def hit(self,p): return any(contains(s,p) for s in self.shapes)

def point(p): return p['x'],p['y']
def board(p,placement):
    x,y=p; x = -x if placement['side']=='bottom' else x
    a=math.radians(placement['rotationDegrees']); c,s=math.cos(a),math.sin(a)
    return (placement['position']['x']+x*c-y*s,placement['position']['y']+x*s+y*c)
def local(world,placement):
    x=world[0]-placement['position']['x']; y=world[1]-placement['position']['y']; a=math.radians(placement['rotationDegrees']); c,s=math.cos(a),math.sin(a)
    xx=x*c+y*s; return (-xx if placement['side']=='bottom' else xx,-x*s+y*c)
def pad_hit(world,pad,placement,margin=0):
    x,y=local(world,placement); x-=pad['center']['x']; y-=pad['center']['y']
    a=-math.radians(pad['rotationDegrees']); x,y=math.cos(a)*x-math.sin(a)*y,math.sin(a)*x+math.cos(a)*y
    hx=pad['size']['x']/2+margin; hy=pad['size']['y']/2+margin
    r= min(hx,hy) if pad['shape'] in ('circle','oval') else max(0,min(pad.get('cornerRadius',0)+margin,min(hx,hy))) if pad['shape']=='roundedRectangle' else 0
    return math.hypot(max(0,abs(x)-(hx-r)),max(0,abs(y)-(hy-r))) <= r if r else abs(x)<=hx and abs(y)<=hy

def run(folder,source):
    doc=json.loads(source.read_text()); d=doc['design']; origin=point(d['board']['assemblyOrigin'])
    manifest=json.loads((folder/'manifest.json').read_text()); assert manifest['revision']==doc['revision'] and manifest['designID']==d['id']
    assert {x['name'] for x in manifest['files']} | {'manifest.json'} == {p.name for p in folder.iterdir()}
    for f in manifest['files']:
        b=(folder/f['name']).read_bytes(); assert len(b)==f['bytes'] and hashlib.sha256(b).hexdigest()==f['sha256']
    layers={name:Gerber(folder/('board-'+name+'.gbr')) for name in ['F_Cu','B_Cu','F_Mask','B_Mask','F_Paste','B_Paste','F_Silkscreen','B_Silkscreen','Profile']}
    expected_funcs=['Copper,L1,Top','Copper,L2,Bot','Soldermask,Top','Soldermask,Bot','Paste,Top','Paste,Bot','Legend,Top','Legend,Bot','Profile,NP']
    for (name,g),function in zip(layers.items(),expected_funcs):
        assert g.attrs['FileFunction']==function; assert g.attrs['FilePolarity']==('Negative' if 'Mask' in name else 'Positive')
        assert g.attrs['SameCoordinates']==f"{d['id']}-{doc['revision']}"
    job=json.loads((folder/'board.gbrjob').read_text()); assert job['GeneralSpecs']['LayerNumber']==2
    assert job['GeneralSpecs']['BoardThickness']==d['board']['thickness']
    assert job['GeneralSpecs']['ProjectId']['Revision']==str(doc['revision'])
    assert len(job['FilesAttributes'])==10
    for attr in job['FilesAttributes']:
        assert (folder/attr['Path']).exists()
        if attr['FileFormat']=='Gerber':
            g=Gerber(folder/attr['Path']); assert g.attrs['FileFunction']==attr['FileFunction'] and g.attrs['FilePolarity']==attr['FilePolarity']
    # Actual profile coordinates, not the bounding box, must be identical after origin subtraction.
    expected=[(p['x']-origin[0],p['y']-origin[1]) for p in d['board']['outline']]
    draws=layers['Profile'].draws; assert len(draws)==len(expected)
    for i,s in enumerate(draws):
        assert distance(s[1][0],expected[i])<EPS and distance(s[1][1],expected[(i+1)%len(expected)])<EPS
        assert s[1][2]==0
    placement={p['componentID']:p for p in d['board']['placements']}
    devices={json.dumps(x['key'],sort_keys=True):x for x in d['library']['devices']}
    footprints={json.dumps(x['key'],sort_keys=True):x for x in d['library']['footprints']}
    expected_holes=[]; samples=0
    for component in d['components']:
        device=devices[json.dumps(component['device'],sort_keys=True)]; footprint=footprints[json.dumps(device['footprint'],sort_keys=True)]; place=placement[component['id']]
        for pad in footprint['pads']:
            center=board(point(pad['center']),place); output_center=(center[0]-origin[0],center[1]-origin[1])
            through='drillDiameter' in pad
            if through: expected_holes.append((*output_center,pad['drillDiameter']))
            sides=['F','B'] if through else ['F' if place['side']=='top' else 'B']
            for side in sides:
                # Flash center must match source even for asymmetric bottom-side/rotated shapes.
                matching=[shapes for p,shapes in layers[side+'_Cu'].flashes if distance(p,output_center)<EPS]
                assert len(matching)==1, (component['reference'],pad['number'],side)
                shapes=[translate(s,*output_center) for s in matching[0]]
                for ix in range(-21,22):
                    for iy in range(-21,22):
                        delta=(ix*0.07319,iy*0.06731)
                        world=(center[0]+delta[0],center[1]+delta[1]); q=(world[0]-origin[0],world[1]-origin[1])
                        assert any(contains(s,q) for s in shapes)==pad_hit(world,pad,place),(component['reference'],pad['number'],q)
                        samples+=1
                for suffix,margin in [('Mask',.05)]+([] if through or component['assembly']=='doNotPopulate' else [('Paste',0)]):
                    matching=[shapes for p,shapes in layers[side+'_'+suffix].flashes if distance(p,output_center)<EPS]
                    assert len(matching)==1
                    shapes=[translate(s,*output_center) for s in matching[0]]
                    for ix in range(-15,16):
                        for iy in range(-15,16):
                            world=(center[0]+ix*.09713,center[1]+iy*.08317); q=(world[0]-origin[0],world[1]-origin[1])
                            assert any(contains(s,q) for s in shapes)==pad_hit(world,pad,place,margin),(suffix,component['reference'],pad['number'],q)
                            samples+=1
    for via in d['board']['copper']['vias']:
        expected_holes.append((via['position']['x']-origin[0],via['position']['y']-origin[1],via['drill']))
    # Every track is drawn with its true circular aperture; endpoint and radius comparison.
    for side,number in [('F',0),('B',1)]:
        expected=[]
        for track in d['board']['copper']['tracks']:
            if track['layer']!=number: continue
            pts=[(p['x']-origin[0],p['y']-origin[1]) for p in track['points']]
            expected.extend((a,b,track['width']/2) for a,b in zip(pts,pts[1:]))
        actual=layers[side+'_Cu'].draws
        assert len(actual)==len(expected)
        for e,a in zip(expected,actual):
            assert distance(e[0],a[1][0])<EPS and distance(e[1],a[1][1])<EPS and abs(e[2]-a[1][2])<EPS
    # Drill parser enforces explicit decimal mm, tool definition before use and no origin/mirror drift.
    tools={}; selected=None; found=[]; lines=(folder/'board-PTH.drl').read_text().splitlines()
    assert lines[0]=='M48' and 'METRIC' in lines and 'G05' in lines and lines[-1]=='M30'
    for line in lines:
        if line.startswith(';') or line in ('M48','METRIC','%','G05','M30'): continue
        if m:=re.fullmatch(r'T(\d{2})C(\d+\.\d+)',line): tools[int(m[1])]=float(m[2])
        elif m:=re.fullmatch(r'T(\d{2})',line): selected=int(m[1]); assert selected in tools
        elif m:=re.fullmatch(r'X(-?\d+\.\d+)Y(-?\d+\.\d+)',line): found.append((float(m[1]),float(m[2]),tools[selected]))
        else: raise AssertionError(('drill syntax',line))
    assert len(found)==len(expected_holes)
    for e in expected_holes: assert any(distance(e,a)<EPS and abs(e[2]-a[2])<EPS for a in found)
    components=list(csv.DictReader(io.StringIO((folder/'components.csv').read_text())))
    assert {r['Designator'] for r in components}=={c['reference'] for c in d['components']}
    # Synthetic fixture uses manual assembly: supplier files MUST NOT invent an LCSC identifier.
    assert list(csv.DictReader(io.StringIO((folder/'assembly-bom.csv').read_text())))==[]
    assert list(csv.DictReader(io.StringIO((folder/'assembly-cpl.csv').read_text())))==[]
    report=json.loads((folder/'preflight.json').read_text()); assert not any(i['severity']=='error' for i in report['issues'])
    print(f'PASS independent fabrication: 9 Gerber layers, {len(found)} PTH holes, {samples} pad/mask/paste probes, common origin, bottom orientation, job and SHA-256 manifest.')

if __name__=='__main__':
    run(Path(sys.argv[1]),Path(sys.argv[2]))
    if len(sys.argv)==4:
        binary=Path(sys.argv[3]).resolve(); source=Path(sys.argv[2]); folder=Path(sys.argv[1])
        # CLI never overwrites an existing package and never leaves output after preflight failure.
        before={p.name:p.read_bytes() for p in folder.iterdir()}
        assert subprocess.run([str(binary),str(source),str(folder)],capture_output=True).returncode!=0
        assert before=={p.name:p.read_bytes() for p in folder.iterdir()}
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); broken=json.loads(source.read_text()); broken['design']['board']['copper']['tracks'].pop(0)
            (root/'broken.ftkc').write_text(json.dumps(broken))
            result=subprocess.run([str(binary),str(root/'broken.ftkc'),str(root/'refused')],capture_output=True,text=True)
            assert result.returncode!=0 and 'pcb_unrouted' in result.stderr and not (root/'refused').exists()
            thermal=json.loads(source.read_text()); design=thermal['design']
            design['board']['copper']['zones']=[dict(id='FAB00000-0000-0000-0000-000000001200',name='Return',netID=design['nets'][2]['id'],layer=1,
                outline=design['board']['outline'],removeIslands=True,connection='thermal',thermalGap=.3,thermalSpokeWidth=.4,
                thermalAngleDegrees=0,minimumSpokes=2,minimumWidth=0)]
            thermal_source=root/'thermal.ftkc'; thermal_source.write_text(json.dumps(thermal))
            result=subprocess.run([str(binary),str(thermal_source),str(root/'thermal')],capture_output=True,text=True)
            assert result.returncode==0,result.stderr
            run(root/'thermal',thermal_source)
            copper=Gerber(root/'thermal'/'board-B_Cu.gbr'); assert len(copper.regions)>10
            origin=point(design['board']['assemblyOrigin']); x,y=5-origin[0],12.46-origin[1]
            assert not copper.hit((x+.73,y+.73)), 'Gerber fills the thermal gap'
            for dx,dy in [(1.2,0),(-1.2,0),(0,1.2),(0,-1.2)]: assert copper.hit((x+dx,y+dy)), 'Gerber loses a full-width spoke'
            print(f'PASS independent thermal Gerber: {len(copper.regions)} filled regions; diagonal relief void and four real spokes preserved.')
        print('PASS atomic CLI: existing package unchanged; unrouted board produces no partial directory.')
