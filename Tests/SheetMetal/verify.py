"""Read the sheet-metal exports independently of CADCore and check them against the
press-brake rule computed here from scratch (T79).

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

# Independent rule: DC01, t = 2 → V = 16 (8t), Ri = 0.16·V rounded up to 0.1, K from DIN 6935.
t = 2.0
v_die = 16
r = math.ceil(0.16 * v_die * 10 - 1e-9) / 10
k = max(0.2, min(0.5, min(1, 0.65 + 0.5 * math.log10(r / t)) / 2))
assert report["vDie"] == v_die and math.isclose(report["insideRadius"], r) and math.isclose(report["kFactor"], k)
assert report["warnings"] == []
setback = r + t                       # 90° outside setback = tan(45°)·(R + t)
straight = 30 - setback               # 30 mm outside flange
plate = 60 - setback                  # 60 mm outside depth
allowance = math.pi / 2 * (r + k * t)
n = 16
bend_section = n / 2 * math.sin(math.pi / 2 / n) * ((r + t) ** 2 - r ** 2)
folded_volume = 40 * (plate * t + bend_section + straight * t)
blank = plate + allowance + straight
assert math.isclose(report["flatArea"], 40 * blank, abs_tol=1e-9)
saved = json.loads((directory / "LBracket.ftk").read_text())
feature = saved["timeline"][0]["content"]["feature"]["_0"]
assert feature["kind"]["sheetMetal"]["_0"]["material"] == "dc01"


def check_mesh(vertices, triangles, volume, minimum, maximum, tolerance=1e-7):
    points = [tuple(v) for v in vertices]
    edges = Counter((points[t[i]], points[t[(i + 1) % 3]]) for t in triangles for i in range(3))
    assert all(a != b and count == 1 and edges[(b, a)] == 1 for (a, b), count in edges.items())
    measured = 0
    for triangle in triangles:
        a, b, c = [points[i] for i in triangle]
        measured += sum(a[j] * (b[(j + 1) % 3] * c[(j + 2) % 3] - b[(j + 2) % 3] * c[(j + 1) % 3]) for j in range(3)) / 6
    assert math.isclose(measured, volume, abs_tol=tolerance), (measured, volume)
    for j in range(3):
        assert math.isclose(min(p[j] for p in points), minimum[j], abs_tol=tolerance), (j, minimum)
        assert math.isclose(max(p[j] for p in points), maximum[j], abs_tol=tolerance), (j, maximum)


data = (directory / "LBracket.stl").read_bytes()
count, = struct.unpack_from("<I", data, 80)
assert len(data) == 84 + 50 * count
stl_vertices = []
for i in range(count):
    values = struct.unpack_from("<12fH", data, 84 + 50 * i)
    stl_vertices.extend([values[3:6], values[6:9], values[9:12]])
stl_triangles = [tuple(range(i, i + 3)) for i in range(0, len(stl_vertices), 3)]
check_mesh(stl_vertices, stl_triangles, folded_volume, (-20, -30, 0), (20, 30, 30), tolerance=0.01)

y0 = -30 + setback
ns = {"c": "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"}
for filename, volume, minimum, maximum, color in [
    ("LBracket.3mf", folded_volume, (-20, -30, 0), (20, 30, 30), "#6C93B5"),
    ("LBracket-flat.3mf", 40 * t * blank, (-20, y0 - allowance - straight, 0), (20, 30, t), "#6EA690"),
]:
    with zipfile.ZipFile(directory / filename) as archive:
        assert archive.testzip() is None
        model = ET.fromstring(archive.read("3D/3dmodel.model"))
        project = json.loads(archive.read("Metadata/project_settings.config"))
        assert project["filament_colour"] == [color]
        assert model.attrib["unit"] == "millimeter"
        meshes = model.findall("c:resources/c:object/c:mesh", ns)
        assert len(meshes) == 1
        vertices = [tuple(float(v.attrib[c]) for c in "xyz") for v in meshes[0].find("c:vertices", ns)]
        triangles = [tuple(int(tr.attrib[c]) for c in ("v1", "v2", "v3")) for tr in meshes[0].find("c:triangles", ns)]
        check_mesh(vertices, triangles, volume, minimum, maximum, tolerance=1e-4)


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
            current.append((code, value))
    assert len(entities) == 4
    values = dict(entities[0])
    assert values[0] == "LWPOLYLINE" and values[8] == "CUT" and values[70] == "1" and values[90] == "4"
    outline = list(zip([float(v) for c, v in entities[0] if c == 10], [float(v) for c, v in entities[0] if c == 20]))
    bottom = y0 - allowance - straight
    expected = [(-20, bottom), (20, bottom), (20, 30), (-20, 30)]
    assert all(math.isclose(a, b, abs_tol=1e-8) for p, q in zip(outline, expected) for a, b in zip(p, q)), outline
    for entity, y, layer in zip(entities[1:], [y0 - allowance / 2, y0, y0 - allowance], [bend_layer, "BEND_TANGENT", "BEND_TANGENT"]):
        line = dict(entity)
        assert line[0] == "LINE" and line[8] == layer
        assert [float(line[c]) for c in (10, 11)] == [-20, 20]
        assert math.isclose(float(line[20]), y, abs_tol=1e-9) and math.isclose(float(line[21]), y, abs_tol=1e-9)
    return outline


outline = read_dxf(directory / "LBracket-flat.dxf", "BEND_UP")
read_dxf(directory / "LBracket-down-flat.dxf", "BEND_DOWN")

flat_points = " ".join(f"{x:.3f},{-y:.3f}" for x, y in outline)
html = f'''<!doctype html><html lang="it"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lamiera — collaudo</title><style>body{{margin:0;background:#f0f3f4;color:#203140;font:16px/1.5 system-ui}}main{{max-width:900px;margin:auto;padding:32px 20px}}
svg{{width:100%;max-width:420px;display:block;background:white;border-radius:12px}}a{{color:#176577}}</style><main>
<h1>Staffa L in DC01 2 mm</h1><p>V{v_die} · Ri {r} mm · K {k:.4f} (DIN 6935) · BA {allowance:.4f} mm · sviluppo 40 × {blank:.3f} mm</p>
<svg viewBox="-30 -40 60 110"><polygon points="{flat_points}" fill="#dcece5" stroke="#397b64" stroke-width="0.4"/>
<path d="M-20,{-(y0 - allowance / 2):.3f}H20" stroke="#ce6e28" stroke-dasharray="2,1" stroke-width=".4"/></svg>
<p><a href="LBracket.3mf">Piegato 3MF</a> · <a href="LBracket.stl">STL</a> · <a href="LBracket-flat.dxf">Sviluppo DXF</a> · <a href="LBracket.ftk">Disegno</a></p></main></html>'''
(directory / "index.html").write_text(html)
print("PASS: independent press-brake rule, STL/3MF closure, bounds and volumes; DXF units, outline, bend/tangent layers")
print(f"Blank: 40 x {blank:.9f} mm; preview: {directory / 'index.html'}")
