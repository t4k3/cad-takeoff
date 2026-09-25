"""Read the actual exports independently of CADCore; build a preview of those bytes.

Standard-library checks, not a substitute for a CAM import or a fabricated sample.
"""
import json
import math
import struct
import sys
import zipfile
from collections import Counter
from pathlib import Path
from xml.etree import ElementTree as ET

directory = Path(sys.argv[1])
report = json.loads((directory / "report.json").read_text())
allowance = math.pi / 2 * (3 + 0.4 * 2)
length = 60 + 30 + allowance
assert math.isclose(report["developedLength"], length, abs_tol=1e-10)
assert math.isclose(report["bendAllowance"], allowance, abs_tol=1e-10)
assert report["manufacturingCalibrated"] is False
saved = json.loads((directory / "LBracket.sheetmetal.json").read_text())
assert saved["id"] == report["partID"] and saved["revision"] == report["partRevision"]
assert [op["id"] for op in saved["operations"]] == report["operationIDs"]


def check_mesh(vertices, triangles, volume, minimum, maximum, tolerance=1e-7):
    # Weld equal positions, including STL's repeated triangle corners.
    points = [tuple(v) for v in vertices]
    edges = Counter((points[t[i]], points[t[(i + 1) % 3]]) for t in triangles for i in range(3))
    assert all(a != b and count == 1 and edges[(b, a)] == 1 for (a, b), count in edges.items())
    measured = 0
    for triangle in triangles:
        a, b, c = [points[i] for i in triangle]
        measured += sum(a[k] * (b[(k+1) % 3] * c[(k+2) % 3] - b[(k+2) % 3] * c[(k+1) % 3]) for k in range(3)) / 6
    assert math.isclose(measured, volume, abs_tol=tolerance), (measured, volume)
    for k in range(3):
        assert math.isclose(min(v[k] for v in points), minimum[k], abs_tol=tolerance)
        assert math.isclose(max(v[k] for v in points), maximum[k], abs_tol=tolerance)


chord_volume = 40 * (180 + 24 * math.sin(math.pi / 48) * (25 - 9) / 2)
data = (directory / "LBracket.stl").read_bytes()
count, = struct.unpack_from("<I", data, 80)
assert len(data) == 84 + 50 * count
stl_vertices = []
for i in range(count):
    values = struct.unpack_from("<12fH", data, 84 + 50 * i)
    stl_vertices.extend([values[3:6], values[6:9], values[9:12]])
stl_triangles = [tuple(range(i, i + 3)) for i in range(0, len(stl_vertices), 3)]
check_mesh(stl_vertices, stl_triangles, chord_volume, (-60, -20, 0), (5, 20, 35), tolerance=0.001)

ns = {"c": "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"}
for filename, volume, maximum, color in [
    ("LBracket.3mf", chord_volume, (5, 20, 35), "#6C93B5"),
    ("LBracket-flat.3mf", 40 * 2 * length, (30 + allowance, 20, 2), "#6EA690"),
]:
    with zipfile.ZipFile(directory / filename) as archive:
        assert archive.testzip() is None
        model = ET.fromstring(archive.read("3D/3dmodel.model"))
        project = json.loads(archive.read("Metadata/project_settings.config"))
        assert project["filament_colour"] == [color]
        assert model.attrib["unit"] == "millimeter"
        meshes = model.findall("c:resources/c:object/c:mesh", ns)
        assert len(meshes) == 1
        vertices = [tuple(float(v.attrib[k]) for k in "xyz") for v in meshes[0].find("c:vertices", ns)]
        triangles = [tuple(int(t.attrib[k]) for k in ("v1", "v2", "v3")) for t in meshes[0].find("c:triangles", ns)]
        check_mesh(vertices, triangles, volume, (-60, -20, 0), maximum)


def read_dxf(path, bend_layer):
    lines = path.read_text().splitlines()
    assert len(lines) % 2 == 0
    pairs = [(int(lines[i]), lines[i + 1]) for i in range(0, len(lines), 2)]
    assert pairs[-1] == (0, "EOF")
    unit = pairs.index((9, "$INSUNITS"))
    assert pairs[unit + 1] == (70, "4")
    section = pairs.index((2, "ENTITIES")) + 1
    end = pairs.index((0, "ENDSEC"), section)
    entities, current = [], None
    for code, value in pairs[section:end]:
        if code == 999:
            continue
        if code == 0:
            current = [(code, value)]
            entities.append(current)
        else:
            assert current is not None
            current.append((code, value))
    assert len(entities) == 4
    polygon = entities[0]
    values = dict(polygon)
    assert values[0] == "LWPOLYLINE" and values[8] == "CUT" and values[70] == "1" and values[90] == "4"
    outline = list(zip([float(v) for c, v in polygon if c == 10], [float(v) for c, v in polygon if c == 20]))
    expected = [(-60, -20), (30 + allowance, -20), (30 + allowance, 20), (-60, 20)]
    assert all(math.isclose(a, b, abs_tol=1e-8) for p, q in zip(outline, expected) for a, b in zip(p, q))
    for entity, x, layer in zip(entities[1:], [allowance / 2, 0, allowance], [bend_layer, "BEND_TANGENT", "BEND_TANGENT"]):
        line = dict(entity)
        assert line[0] == "LINE" and line[8] == layer
        assert math.isclose(float(line[10]), x, abs_tol=1e-9)
        assert math.isclose(float(line[11]), x, abs_tol=1e-9)
        assert [float(line[c]) for c in (20, 21, 30, 31)] == [-20, 20, 0, 0]
    return outline


outline = read_dxf(directory / "LBracket-flat.dxf", "BEND_UP")
read_dxf(directory / "LBracket-down-flat.dxf", "BEND_DOWN")

# Static technical preview, generated from the parsed STL and DXF, not a UI mockup.
def project(v):
    return (v[0] + v[1], 0.45 * v[0] - 0.45 * v[1] - v[2])


projected = [project(v) for v in stl_vertices]
low = [min(p[k] for p in projected) for k in range(2)]
high = [max(p[k] for p in projected) for k in range(2)]
scale = min(570 / (high[0] - low[0]), 285 / (high[1] - low[1]))


def screen(v):
    p = project(v)
    return (320 + (p[0] - (high[0] + low[0]) / 2) * scale,
            185 + (p[1] - (high[1] + low[1]) / 2) * scale)


polygons = []
camera = (0.45, -0.45, 1)
for triangle in stl_triangles:
    vertices = [stl_vertices[i] for i in triangle]
    a, b, c = vertices
    ab, ac = [b[k] - a[k] for k in range(3)], [c[k] - a[k] for k in range(3)]
    normal = [ab[(k+1) % 3] * ac[(k+2) % 3] - ab[(k+2) % 3] * ac[(k+1) % 3] for k in range(3)]
    norm = math.sqrt(sum(n*n for n in normal))
    facing = sum(normal[k] * camera[k] for k in range(3))
    if facing <= 0:
        continue
    shade = 0.65 + 0.35 * facing / norm / math.sqrt(sum(v*v for v in camera))
    fill = "#" + "".join(f"{round(v * shade):02x}" for v in (135, 184, 214))
    coords = " ".join(f"{x:.2f},{y:.2f}" for x, y in map(screen, vertices))
    depth = sum(sum(v[k] * camera[k] for k in range(3)) for v in vertices) / 3
    polygons.append((depth, f'<polygon points="{coords}" fill="{fill}" stroke="{fill}" stroke-width="0.5"/>'))
folded_svg = '<svg viewBox="0 0 640 370" role="img" aria-label="Staffa piegata ricavata dal file STL">' + "".join(p for _, p in sorted(polygons)) + '</svg>'
flat_points = " ".join(f"{x},{y}" for x, y in outline)
flat_svg = f'''<svg viewBox="-75 -38 130 83" role="img" aria-label="Sviluppo letto dal DXF">
<polygon points="{flat_points}" fill="#dcece5" stroke="#397b64" stroke-width="0.5"/>
<rect x="0" y="-20" width="{allowance}" height="40" fill="#dba45c" opacity=".25"/>
<path d="M0,-20V20 M{allowance},-20V20" stroke="#a5845b" stroke-dasharray="1,1" stroke-width=".3"/>
<path d="M{allowance/2},-20V20" stroke="#ce6e28" stroke-dasharray="2,1" stroke-width=".5"/>
<g font-family="system-ui" font-size="3" fill="#48615a" text-anchor="middle">
<text x="-30" y="2">BASE · 60</text><text x="{allowance + 15}" y="2">FLANGIA · 30</text>
<text x="{allowance/2}" y="-25">BA {allowance:.3f}</text><text x="-12" y="34">{length:.3f} mm</text>
<text x="45" y="1" transform="rotate(-90 45 1)">40 mm</text></g>
<path d="M-60,24V31 M{30+allowance},24V31 M-60,29H{30+allowance} M39,-20H43 M39,20H43 M41,-20V20" stroke="#78928a" stroke-width=".25"/>
</svg>'''
html = f'''<!doctype html><html lang="it"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lamiera — prima base verificata</title><style>
*{{box-sizing:border-box}}body{{margin:0;background:#f0f3f4;color:#203140;font:16px/1.5 system-ui}}main{{max-width:1200px;margin:auto;padding:42px 32px}}
.eyebrow{{font-size:12px;letter-spacing:.13em;font-weight:700;color:#487367}}h1{{font-size:36px;letter-spacing:-.035em;margin:12px 0}}p{{color:#586773;max-width:850px}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin:30px 0}}.card{{background:white;border:1px solid #dce3e5;border-radius:16px;padding:22px}}h2{{font-size:19px;margin:0}}svg{{width:100%;display:block}}small{{color:#586773}}.specs{{display:flex;flex-wrap:wrap;gap:10px}}
.specs span{{background:#e4ecef;padding:8px 14px;border-radius:8px}}a{{color:#176577}}.links{{display:flex;flex-wrap:wrap;gap:18px;margin-top:18px}}.note{{border-left:3px solid #bd914e;padding-left:16px}}@media(max-width:780px){{.grid{{grid-template-columns:1fr}}main{{padding:24px 18px}}}}
</style><main><div class="eyebrow">FUSION TAKEOFF / CADCORE / T78</div><h1>La prima staffa in lamiera</h1>
<p>Una base rettangolare e una flangia a 90°. Geometria piegata e sviluppo sono rigenerati dalle operazioni salvate. Questa è una verifica del motore; il pannello nell’app è il prossimo collegamento con Claude.</p>
<div class="specs"><span>Spessore <b>2 mm</b></span><span>Raggio interno <b>3 mm</b></span><span>Larghezza <b>40 mm</b></span><span>K <b>0,4 · prova</b></span></div>
<div class="grid"><section class="card"><h2>Modello piegato</h2>{folded_svg}<small>Anteprima dal file STL · mesh chiusa · scostamento massimo dalla curva {report['maximumSurfaceDeviation']:.4f} mm</small></section>
<section class="card"><h2>Sviluppo piano</h2>{flat_svg}<small>Contorno letto dal DXF · arancione: linea centrale della piega · tratteggi sottili: tangenti</small></section></div>
<section class="card"><h2>File di prova</h2><div class="links"><a href="LBracket.3mf">Piegato 3MF</a><a href="LBracket.stl">Piegato STL</a><a href="LBracket-flat.dxf">Sviluppo DXF</a><a href="LBracket-flat.3mf">Sviluppo 3MF</a><a href="LBracket.sheetmetal.json">Operazioni JSON</a><a href="report.json">Misure</a></div></section>
<p class="note">Lunghezze 60 e 30 mm misurate dalle tangenti. Sviluppo = 60 + 30 + π/2 × (3 + 0,4 × 2) = {length:.3f} mm. Il K-factor è un valore di prova da calibrare sul processo di piega. Nessuna prova in officina o import CAM inclusa.</p>
<p><a href="../../docs/requirements/SHEET_METAL_V1.md">Contratto tecnico e limiti della base</a> · <a href="../../docs/architecture/index.html">Grafo del progetto</a></p></main></html>'''
(directory / "index.html").write_text(html)
print("PASS: independent STL/3MF closure, winding, bounds and volumes; DXF units, outline, bend/tangent layers")
print(f"Flat length: {length:.9f} mm; preview: {directory / 'index.html'}")
