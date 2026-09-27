#!/usr/bin/env python3
"""Independent JSON/CLI consumer. Golden dimensions come from the pinned source corpus.

No Swift parser/geometry code is reused. EasyEDA/catalog cases are explicitly synthetic.
All generated files stay in the supplied fresh build directory.
"""
import hashlib
import json
import math
import subprocess
import sys
from pathlib import Path

binary, fixtures, root = (Path(p).resolve() for p in sys.argv[1:])
root.mkdir()
library = fixtures / "Library"


def write(name, value):
    path = root / name
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    return path


def read(path):
    return json.loads(path.read_text())


def run(*args, error=None):
    result = subprocess.run([str(binary), *(str(a) for a in args)], capture_output=True, text=True)
    if error:
        assert result.returncode == 1 and error in result.stderr, (args, result)
    else:
        assert result.returncode == 0, (args, result)
    return result


def context(index):
    return write(f"context-{index}.json", {
        "key": {"id": f"AAAAAAAA-0000-0000-0000-{index:012d}", "revision": 1},
        "source": {"reference": "Pinned test corpus; see sources.json", "license": "See KICAD_LICENSE.md or synthetic test data",
                   "sourceRevision": "9.0.0 / test-1"},
        "assemblyCentroid": {"x": 0, "y": 0},
    })


manifest = read(library / "sources.json")
for source in manifest["sources"]:
    assert hashlib.sha256((library / source["file"]).read_bytes()).hexdigest() == source["sha256"]

fp_path, symbol_path, header_path = (root / f"{name}.json" for name in ["footprint", "symbol", "header"])
fp_context = context(1)
run("kicad-footprint", library / "R_0603_1608Metric.kicad_mod", fp_context, fp_path)
run("kicad-symbol", library / "Device_R.kicad_sym", context(2), "R", symbol_path)
run("kicad-footprint", library / "PinHeader_1x02.kicad_mod", context(3), header_path)
fp_bundle, sym_bundle, header_bundle = (read(p) for p in [fp_path, symbol_path, header_path])
for bundle, name in [(fp_bundle, "R_0603_1608Metric.kicad_mod"), (sym_bundle, "Device_R.kicad_sym"), (header_bundle, "PinHeader_1x02.kicad_mod")]:
    source = (library / name).read_bytes()
    assert bundle["originalSource"].encode() == source
    assert bundle["sourceSHA256"] == hashlib.sha256(source).hexdigest()
    assert not any(issue["severity"] == "error" for issue in bundle["issues"])
    assert all(issue.get("subjectIDs") for issue in bundle["issues"])
fp = fp_bundle["library"]["footprints"][0]
assert [pad["number"] for pad in fp["pads"]] == ["1", "2"]
assert all(pad["shape"] == "roundedRectangle" for pad in fp["pads"])
assert math.isclose(fp["pads"][0]["cornerRadius"], 0.2, abs_tol=1e-9)
assert math.isclose(fp["pads"][1]["center"]["x"] - fp["pads"][0]["center"]["x"], 1.65, abs_tol=1e-9)
assert len(fp["graphics"]) == 10
pins = sym_bundle["library"]["symbols"][0]["pins"]
assert [pin["number"] for pin in pins] == ["1", "2"]
assert [pin["position"]["y"] for pin in pins] == [3.81, -3.81]
header = header_bundle["library"]["footprints"][0]
assert all(pad["drillDiameter"] == 1 for pad in header["pads"])
assert header["pads"][1]["center"]["y"] == -2.54

easy_source = write("easyeda-source.json", {"head": {"docType": "4", "x": "4000", "y": "3000"},
    "shape": ["PAD~RECT~4010~3020~4~6~1~~1~0~~90~gge1~0~~Y~0~~~"]})
easy_path = root / "easyeda.json"
run("easyeda-footprint", easy_source, context(4), "Synthetic orthogonal SMD", easy_path)
pad = read(easy_path)["library"]["footprints"][0]["pads"][0]
assert math.isclose(pad["center"]["x"], 2.54, abs_tol=1e-9)
assert math.isclose(pad["center"]["y"], -5.08, abs_tol=1e-9)
assert math.isclose(pad["size"]["x"], 1.016, abs_tol=1e-9)
assert math.isclose(pad["size"]["y"], 1.524, abs_tol=1e-9)

csv = root / "catalog.csv"
csv.write_text('LCSC Part #,Manufacturer,MPN,Package,Description,Stock,Datasheet\n'
               'C000001,Fixture maker,TEST-1,0603,"10k, 1% ""thin""",20,https://example.invalid/test.pdf\n'
               'C000002,Fixture maker,TEST-2,0805,Unknown stock,,\n')
meta = write("catalog-meta.json", {"sourceReference": "Synthetic; not a purchasable catalog", "observedAt": "2026-09-27T08:00:00Z",
    "columns": {"partNumber": "LCSC Part #", "manufacturer": "Manufacturer", "mpn": "MPN", "package": "Package",
                "description": "Description", "stock": "Stock", "datasheet": "Datasheet"}})
catalog_path = root / "catalog.json"
run("catalog", csv, meta, catalog_path)
catalog = read(catalog_path)
assert catalog["sourceSHA256"] == hashlib.sha256(csv.read_bytes()).hexdigest()
assert catalog["observedAt"] == "2026-09-27T08:00:00Z"
assert catalog["parts"][0]["description"] == '10k, 1% "thin"'
assert catalog["parts"][0]["stock"] == 20
assert catalog["parts"][1].get("stock") is None

original = fixtures / "assembly.json"
first, second, same = (root / f"document-{name}.json" for name in ["first", "second", "same"])
run("apply-import", original, fp_path, 0, first)
run("apply-import", first, symbol_path, 1, second)
run("apply-import", second, symbol_path, 2, same)
one, two = read(first), read(second)
assert one["formatVersion"] == two["formatVersion"] == 7
assert one["revision"] == 1 and len(one["past"]) == 1
assert two["revision"] == 2 and len(two["past"]) == 2
assert one["past"][0]["before"] == read(original)["design"]
assert two["past"][0]["after"] == two["past"][1]["before"]
assert two["past"][1]["after"] == two["design"]
assert read(same) == two  # An identical reimport must not add an undo step.
assert len(two["design"]["library"]["symbols"]) == len(read(original)["design"]["library"]["symbols"]) + 1

bad_output = root / "should-not-exist.json"
before_bytes = second.read_bytes()
run("apply-import", second, fp_path, 0, bad_output, error="stale_revision")
assert not bad_output.exists() and second.read_bytes() == before_bytes
before_bytes = fp_path.read_bytes()
run("kicad-footprint", library / "R_0603_1608Metric.kicad_mod", fp_context, fp_path, error="output_exists")
assert fp_path.read_bytes() == before_bytes
bad_source = root / "unsupported.kicad_mod"
bad_source.write_text('(footprint X (layer F.Cu) (pad 1 smd custom (at 0 0) (size 1 1) (layers F.Cu)))')
run("kicad-footprint", bad_source, fp_context, bad_output, error="unsupported_pad")
assert not bad_output.exists()
print("PASS: independent library CLI, pinned source hashes, KiCad geometry, EasyEDA units, offline catalog, v1 migration, atomic history and no overwrite.")
