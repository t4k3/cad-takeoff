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


# --- the Base cube's history: a 2 × 2 cm square sketched on XY, sides «lato», extruded 2 cm ---
class Obj(types.SimpleNamespace):
    """A Fusion object: its type name and a stable token."""
    def __init__(self, kind, **kw):
        super().__init__(objectType="adsk::fusion::" + kind, entityToken="%s-%d" % (kind, id(self)), **kw)


class Coll(list):
    @property
    def count(self):
        return len(self)

    def item(self, i):
        return self[i]


def P3(x, y, z=0.0):
    return types.SimpleNamespace(x=x, y=y, z=z)


class Evaluator:
    def __init__(self, pts):
        self.pts = pts

    def getParameterExtents(self):
        return True, 0.0, 1.0

    def getStrokes(self, t0, t1, tol):
        return True, self.pts


class Matrix:
    def getAsCoordinateSystem(self):
        return P3(0, 0, 0), P3(1, 0, 0), P3(0, 1, 0), P3(0, 0, 1)


class Param:
    def __init__(self, name, expression, value, unit="mm", comment=""):
        self.name, self.expression, self.value, self.unit, self.comment = name, expression, value, unit, comment


corners = [Obj("SketchPoint", geometry=P3(x, y), isFixed=(x == 0 and y == 0)) for x, y in ((0, 0), (2, 0), (2, 2), (0, 2))]
lines = [Obj("SketchLine", startSketchPoint=corners[i], endSketchPoint=corners[(i + 1) % 4], isConstruction=False) for i in range(4)]
lato = Param("lato", "20 mm", 2.0)
profile_curves = [types.SimpleNamespace(geometry=types.SimpleNamespace(evaluator=Evaluator([P3(0, 0), P3(2, 0), P3(2, 2), P3(0, 2)])))]
profile = Obj("Profile", areaProperties=lambda: types.SimpleNamespace(area=4.0),
              profileLoops=[types.SimpleNamespace(profileCurves=profile_curves)])
sketch = Obj("Sketch", name="Schizzo1", transform=Matrix(), originPoint=corners[0], sketchPoints=Coll(corners),
             sketchCurves=Coll(lines), profiles=Coll([profile]),
             geometricConstraints=Coll([Obj("HorizontalConstraint", line=lines[0]), Obj("HorizontalConstraint", line=lines[2]),
                                        Obj("VerticalConstraint", line=lines[1]), Obj("VerticalConstraint", line=lines[3])]),
             sketchDimensions=Coll([Obj("SketchLinearDimension", isDriving=True, orientation=1, parameter=Param("d1", "lato", 2.0),
                                        entityOne=corners[0], entityTwo=corners[1]),
                                    Obj("SketchLinearDimension", isDriving=True, orientation=2, parameter=Param("d2", "lato", 2.0),
                                        entityOne=corners[1], entityTwo=corners[2])]))
profile.parentSketch = sketch
extrude = Obj("ExtrudeFeature", name="Estrusione1", profile=profile, operation=3, hasTwoExtents=False,
              extentOne=Obj("DistanceExtentDefinition", distance=Param("d3", "lato", 2.0)),
              taperAngleOne=Param("d4", "0 deg", 0.0, "deg"),
              startFaces=Coll([Obj("BRepFace", pointOnFace=P3(1, 1, 0))]), endFaces=Coll([Obj("BRepFace", pointOnFace=P3(1, 1, 2))]))
timeline = Coll([types.SimpleNamespace(entity=sketch, isSuppressed=False, isRolledBack=False),
                 types.SimpleNamespace(entity=extrude, isSuppressed=False, isRolledBack=False)])

base = Body("Base", cube(0, 0, 0, 2), Colour(200, 30, 30))
base.physicalProperties = types.SimpleNamespace(volume=8.0)
base.boundingBox = types.SimpleNamespace(minPoint=P3(0, 0, 0), maxPoint=P3(2, 2, 2))
root = types.SimpleNamespace(
    bRepBodies=[base, Body("Nascosto", cube(9, 9, 9, 1), Colour(0, 0, 0), visible=False)],
    allOccurrences=[types.SimpleNamespace(name="Perno:1", isLightBulbOn=True,
                                          bRepBodies=[Body("Corpo1", cube(5, 0, 0, 1), Colour(20, 40, 220))])])
design = types.SimpleNamespace(rootComponent=root, designType=1, timeline=timeline,
                               userParameters=Coll([lato]), allParameters=Coll([lato, Param("d1", "lato", 2.0),
                                                                               Param("d2", "lato", 2.0), Param("d3", "lato", 2.0)]))
sketch.parentComponent = root
extrude.parentComponent = root
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
# The extrusion's real start and end along its sketch's normal (mm), measured on its faces.
import json
with open(path) as fh:
    extent = json.load(fh)["fusion"]["features"][0]["extent"]
assert abs(extent["measuredStart"]) < 1e-9 and abs(extent["measuredEnd"] - 20) < 1e-9, extent
print("fake Fusion export:", path)
