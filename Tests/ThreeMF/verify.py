"""Independent ZIP/CRC/XML and geometry checks on the actual Swift exporter output."""
import sys
import json
import zipfile
import xml.etree.ElementTree as ET
from collections import Counter

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None, "CRC mismatch"
    assert set(archive.namelist()) == {"[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model", "Metadata/model_settings.config", "Metadata/project_settings.config"}
    for name in archive.namelist():
        if name != "Metadata/project_settings.config":
            ET.fromstring(archive.read(name))
    project = json.loads(archive.read("Metadata/project_settings.config"))
    assert project == {"filament_colour": ["#E53935", "#1E88E5"]}, "no machine, material/process presets or G-code"
    settings = ET.fromstring(archive.read("Metadata/model_settings.config"))
    rel = ET.fromstring(archive.read("_rels/.rels"))[0]
    assert rel.attrib["Target"] == "/3D/3dmodel.model"
    model = ET.fromstring(archive.read("3D/3dmodel.model"))
ns = {"c": "http://schemas.microsoft.com/3dmanufacturing/core/2015/02",
      "m": "http://schemas.microsoft.com/3dmanufacturing/material/2015/02"}
assert model.attrib["unit"] == "millimeter" and model.attrib["requiredextensions"] == "m"
resources = model.find("c:resources", ns)
assert len(set(r.attrib["id"] for r in resources)) == len(resources), "duplicate resource ID"
colors = {g.attrib["id"]: [c.attrib["color"] for c in g] for g in resources.findall("m:colorgroup", ns)}
objects = {o.attrib["id"]: o for o in resources.findall("c:object", ns)}
build = model.find("c:build", ns)
assert len(build) == 1
assembly = objects[build[0].attrib["objectid"]]
assert "pid" not in assembly.attrib and "pindex" not in assembly.attrib
components = assembly.find("c:components", ns)
assert len(components) == 2
expected = [("Base rossa & <supporto>", "#E53935FF", 6000, (-20, -15, 0), (20, 15, 5)),
            ("Inserto blu", "#1E88E5FF", 800, (-5, -5, 5), (5, 5, 13))]
for ref, (name, color, volume, minimum, maximum) in zip(components, expected):
    obj = objects[ref.attrib["objectid"]]
    assert obj.attrib["name"] == name
    assert colors[obj.attrib["pid"]][int(obj.attrib["pindex"])] == color
    vertices = [tuple(float(v.attrib[k]) for k in "xyz") for v in obj.find("c:mesh/c:vertices", ns)]
    triangles = [tuple(int(t.attrib[k]) for k in ("v1", "v2", "v3")) for t in obj.find("c:mesh/c:triangles", ns)]
    assert tuple(min(v[k] for v in vertices) for k in range(3)) == minimum
    assert tuple(max(v[k] for v in vertices) for k in range(3)) == maximum
    edges = Counter((t[i], t[(i + 1) % 3]) for t in triangles for i in range(3))
    assert all(n == 1 and edges[(b, a)] == 1 for (a, b), n in edges.items())
    signed_volume = 0
    for t in triangles:
        a, b, c = [vertices[i] for i in t]
        signed_volume += sum(a[k] * (b[(k+1)%3] * c[(k+2)%3] - b[(k+2)%3] * c[(k+1)%3]) for k in range(3)) / 6
    assert abs(signed_volume - volume) < 1e-8
part_settings = settings.find("object")
assert part_settings.attrib["id"] == assembly.attrib["id"]
for i, part in enumerate(part_settings.findall("part")):
    assert part.attrib["id"] == components[i].attrib["objectid"]
    metadata = {m.attrib["key"]: m.attrib["value"] for m in part.findall("metadata")}
    assert metadata == {"name": expected[i][0], "extruder": str(i + 1)}
print("PASS: independent 3MF ZIP/CRC/XML, colours, named parts, placement, dimensions, winding and volumes")
