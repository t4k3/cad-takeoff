"""Runs the Fusion 360 add-in's export against a stand-in for the Fusion API (`adsk`).

Fusion itself cannot run in CI: this checks the add-in's own logic (units, Y-up rotation,
components, colours, the .ftk JSON) with a cube body in the root and one in a component.
The produced file is then opened by the real CADCore (Check.swift).
"""
import importlib.util
import os
import sys
import types

out = sys.argv[1]

# --- minimal adsk stand-in -------------------------------------------------------------
adsk = types.ModuleType("adsk")
core = types.ModuleType("adsk.core")
fusion = types.ModuleType("adsk.fusion")
adsk.core, adsk.fusion = core, fusion


class Handler:  # base classes the add-in subclasses
    pass


for name in ("CommandEventHandler", "InputChangedEventHandler", "CommandCreatedEventHandler", "DocumentEventHandler"):
    setattr(core, name, Handler)
core.DefaultModelingOrientations = types.SimpleNamespace(YUpModelingOrientation=1, ZUpModelingOrientation=2)
fusion.TriangleMeshQualityOptions = types.SimpleNamespace(HighQualityTriangleMesh=3)


class Colour:
    def __init__(self, r, g, b):
        self.red, self.green, self.blue = r, g, b


class ColourProperty:
    def __init__(self, c):
        self.value = c


class Props:
    def __init__(self, c):
        self.c = c
        self.count = 1

    def itemByName(self, name):
        return ColourProperty(self.c) if name == "Color" else None

    def item(self, i):
        return ColourProperty(self.c)


core.ColorProperty = types.SimpleNamespace(cast=lambda p: p)


def cube(x0, y0, z0, s):
    """Closed cube in centimetres (Fusion's internal unit), outward CCW triangles."""
    v = [(x0 + dx * s, y0 + dy * s, z0 + dz * s) for dz in (0, 1) for dy in (0, 1) for dx in (0, 1)]
    quads = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
    tris = [i for a, b, c, d in quads for i in (a, b, c, a, c, d)]
    return [c for p in v for c in p], tris


class Body:
    def __init__(self, name, mesh, colour, visible=True):
        self.name, self.isVisible, self.isSolid = name, visible, True
        coords, idx = mesh
        calc = types.SimpleNamespace(setQuality=lambda q: None,
                                     calculate=lambda: types.SimpleNamespace(nodeCoordinatesAsDouble=coords, nodeIndices=idx))
        self.meshManager = types.SimpleNamespace(createMeshCalculator=lambda: calc)
        self.appearance = types.SimpleNamespace(appearanceProperties=Props(colour))


root = types.SimpleNamespace(
    bRepBodies=[Body("Base", cube(0, 0, 0, 2), Colour(200, 30, 30)), Body("Nascosto", cube(9, 9, 9, 1), Colour(0, 0, 0), visible=False)],
    allOccurrences=[types.SimpleNamespace(name="Perno:1", isLightBulbOn=True,
                                          bRepBodies=[Body("Corpo1", cube(5, 0, 0, 1), Colour(20, 40, 220))])])
design = types.SimpleNamespace(rootComponent=root)
fusion.Design = types.SimpleNamespace(cast=lambda p: p)
app = types.SimpleNamespace(
    activeProduct=design, activeDocument=types.SimpleNamespace(name="Staffa v3"),
    preferences=types.SimpleNamespace(generalPreferences=types.SimpleNamespace(defaultModelingOrientation=1)))  # Y up
sys.modules["adsk"], sys.modules["adsk.core"], sys.modules["adsk.fusion"] = adsk, core, fusion

# --- run the add-in's export -------------------------------------------------------------
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("addin", os.path.join(here, "../../App/Resources/FusionAddIn/FusionTakeoffExport.py"))
addin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(addin)
path, count = addin.export_design(app, out)
assert count == 2 and os.path.basename(path) == "Staffa v3.ftk", (path, count)
print("fake Fusion export:", path)
