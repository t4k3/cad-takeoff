"""Reads a Fusion 360 design's history for CAD Takeoff (the `fusion` block of a .ftk).

Parameters, sketches (points, curves, constraints, dimensions with their expressions, profiles)
and features (extrusions, revolutions, fillets, chamfers, holes, shells) in millimetres and
degrees, in world coordinates (Z up), plus the finished bodies to check the rebuilt ones against.
CAD Takeoff rebuilds what it can as editable steps; a body it cannot rebuild exactly keeps the
mesh the add-in writes next to it. Every entity is read on its own: one Fusion object this code
does not know is skipped (and reported), never the whole export.
"""
import math
import traceback

CM = 10.0  # Fusion's internal length unit is the centimetre


def kind(obj):
    try:
        return obj.objectType.split("::")[-1]
    except Exception:
        return type(obj).__name__


def token(obj):
    try:
        return obj.entityToken
    except Exception:
        return str(id(obj))


class Frame:
    """Component space → world (mm), and Fusion's Y-up turned Z-up like the meshes."""

    def __init__(self, matrix=None, y_up=False):
        self.m = matrix  # adsk.core.Matrix3D or None (identity), in cm
        self.y_up = y_up

    def _apply(self, x, y, z, w):
        if self.m is not None:
            a = self.m.asArray()
            x, y, z = (a[0] * x + a[1] * y + a[2] * z + a[3] * w,
                       a[4] * x + a[5] * y + a[6] * z + a[7] * w,
                       a[8] * x + a[9] * y + a[10] * z + a[11] * w)
        if self.y_up:
            x, y, z = x, -z, y
        return [x, y, z]

    def point(self, p):
        return [c * CM for c in self._apply(p.x, p.y, p.z, 1.0)]

    def vector(self, v):
        return self._apply(v.x, v.y, v.z, 0.0)


def length_value(param):
    """A length parameter's value in mm, an angle's in degrees, anything else as is."""
    unit = (getattr(param, "unit", "") or "").strip()
    value = param.value
    if unit in ("deg", "rad") or "°" in unit:
        return math.degrees(value)
    if unit in ("mm", "cm", "m", "in", "ft", "um", "µm") or unit == "":
        return value * CM if unit != "" else value
    return value


def parameters(design):
    out = []
    try:
        users = design.userParameters
        user_names = set(users.item(i).name for i in range(users.count))
        everything = design.allParameters
        for i in range(everything.count):
            p = everything.item(i)
            try:
                out.append({"name": p.name, "expression": p.expression, "value": length_value(p),
                            "comment": getattr(p, "comment", "") or "", "isUser": p.name in user_names})
            except Exception:
                pass
    except Exception:
        pass
    return out


class SketchReader:
    def __init__(self, sketch, sid, frame, notes):
        self.sketch, self.sid, self.frame, self.notes = sketch, sid, frame, notes
        self.points, self.point_ids, self.curve_ids = [], {}, {}

    def pid(self, point):
        return self.point_ids.get(token(point))

    def cid(self, curve):
        return self.curve_ids.get(token(curve))

    def read(self):
        s = self.sketch
        # The sketch plane in the world: its transform (sketch → component) then the component's.
        t = s.transform
        origin, x_axis, y_axis, _ = t.getAsCoordinateSystem()
        plane = {"origin": self.frame.point(origin), "xAxis": self.frame.vector(x_axis), "yAxis": self.frame.vector(y_axis)}
        origin_token = token(s.originPoint) if getattr(s, "originPoint", None) is not None else None
        pts = s.sketchPoints
        for i in range(pts.count):
            p = pts.item(i)
            key = "p%d" % i
            self.point_ids[token(p)] = key
            g = p.geometry
            fixed = bool(getattr(p, "isFixed", False) or getattr(p, "isReference", False) or token(p) == origin_token)
            self.points.append({"id": key, "x": g.x * CM, "y": g.y * CM, "fixed": fixed})
        curves = []
        all_curves = s.sketchCurves
        for i in range(all_curves.count):
            c = all_curves.item(i)
            key = "c%d" % i
            try:
                entry = self.curve(c, key)
            except Exception:
                entry = None
            if entry is None:
                continue
            entry["construction"] = bool(getattr(c, "isConstruction", False))
            self.curve_ids[token(c)] = key
            curves.append(entry)
        return dict(plane, id=self.sid, name=s.name, points=self.points, curves=curves,
                    constraints=self.constraints(), dimensions=self.dimensions(), profiles=self.profiles())

    def curve(self, c, key):
        k = kind(c)
        if k == "SketchLine":
            return {"type": "line", "id": key, "start": self.pid(c.startSketchPoint), "end": self.pid(c.endSketchPoint)}
        if k == "SketchCircle":
            return {"type": "circle", "id": key, "center": self.pid(c.centerSketchPoint), "radius": c.radius * CM}
        if k == "SketchArc":
            start, end = c.startSketchPoint, c.endSketchPoint
            try:
                if c.geometry.normal.z < 0:          # clockwise in the sketch: the other way round
                    start, end = end, start
            except Exception:
                pass
            return {"type": "arc", "id": key, "center": self.pid(c.centerSketchPoint), "start": self.pid(start),
                    "end": self.pid(end), "radius": c.radius * CM}
        # Splines, ellipses, conics…: their shape as a fine polyline (exact profiles; not editable).
        ev = c.geometry.evaluator
        ok, p0, p1 = ev.getParameterExtents()
        ok, pts = ev.getStrokes(p0, p1, 0.001)
        if not ok or len(pts) < 2:
            return None
        closed = abs(pts[0].x - pts[-1].x) < 1e-7 and abs(pts[0].y - pts[-1].y) < 1e-7
        if closed:
            pts = pts[:-1]
        return {"type": "polyline", "id": key, "polyline": [[p.x * CM, p.y * CM] for p in pts], "closed": closed}

    def ref(self, entity):
        if entity is None:
            return None
        return self.pid(entity) if kind(entity) == "SketchPoint" else self.cid(entity)

    def constraints(self):
        out = []
        names = {"HorizontalConstraint": ("horizontal", ["line"]), "VerticalConstraint": ("vertical", ["line"]),
                 "CoincidentConstraint": ("coincident", ["point", "entity"]),
                 "ParallelConstraint": ("parallel", ["lineOne", "lineTwo"]),
                 "PerpendicularConstraint": ("perpendicular", ["lineOne", "lineTwo"]),
                 "TangentConstraint": ("tangent", ["curveOne", "curveTwo"]),
                 "EqualConstraint": ("equal", ["curveOne", "curveTwo"]),
                 "ConcentricConstraint": ("concentric", ["entityOne", "entityTwo"]),
                 "MidPointConstraint": ("midpoint", ["point", "midPointCurve"]),
                 "SymmetryConstraint": ("symmetry", ["entityOne", "entityTwo", "symmetryLine"])}
        cs = self.sketch.geometricConstraints
        for i in range(cs.count):
            c = cs.item(i)
            k = kind(c)
            if k not in names:
                continue
            name, fields = names[k]
            try:
                refs = [self.ref(getattr(c, f)) for f in fields]
            except Exception:
                continue
            if any(r is None for r in refs):
                continue
            out.append(dict(zip(["a", "b", "c"], refs), type=name))
        return out

    def dimensions(self):
        out = []
        ds = self.sketch.sketchDimensions
        for i in range(ds.count):
            d = ds.item(i)
            try:
                if not getattr(d, "isDriving", True):
                    continue
                k = kind(d)
                p = d.parameter
                value, expression = length_value(p), p.expression
                if k == "SketchLinearDimension":
                    orientation = str(getattr(d, "orientation", ""))
                    t = "distance"
                    try:
                        import adsk.fusion
                        if d.orientation == adsk.fusion.DimensionOrientations.HorizontalDimensionOrientation:
                            t = "horizontal"
                        elif d.orientation == adsk.fusion.DimensionOrientations.VerticalDimensionOrientation:
                            t = "vertical"
                    except Exception:
                        t = {"1": "horizontal", "2": "vertical"}.get(orientation, "distance")
                    a, b = self.ref(d.entityOne), self.ref(d.entityTwo)
                elif k == "SketchOffsetDimension":
                    t, a, b = "distance", self.ref(d.line), self.ref(d.entityTwo)
                elif k == "SketchDiameterDimension":
                    t, a, b = "diameter", self.ref(d.entity), None
                elif k == "SketchRadialDimension":
                    t, a, b = "radius", self.ref(d.entity), None
                elif k == "SketchAngularDimension":
                    t, a, b = "angle", self.ref(d.lineOne), self.ref(d.lineTwo)
                else:
                    continue
                if a is None:
                    continue
                entry = {"type": t, "a": a, "value": value, "expression": expression}
                if b is not None:
                    entry["b"] = b
                out.append(entry)
            except Exception:
                continue
        return out

    def profiles(self):
        out = []
        ps = self.sketch.profiles
        for i in range(ps.count):
            p = ps.item(i)
            try:
                area = p.areaProperties().area * CM * CM
                xs, ys = [], []
                for loop in p.profileLoops:
                    for pc in loop.profileCurves:
                        ev = pc.geometry.evaluator
                        ok, t0, t1 = ev.getParameterExtents()
                        ok, pts = ev.getStrokes(t0, t1, 0.001)
                        for q in pts:
                            # Profile curves may come in model space: back to the sketch's.
                            if abs(q.z) > 1e-7:
                                q = self.sketch.modelToSketchSpace(q)
                            xs.append(q.x * CM)
                            ys.append(q.y * CM)
                if xs:
                    out.append({"id": "P%d" % i, "area": area, "min": [min(xs), min(ys)], "max": [max(xs), max(ys)]})
            except Exception:
                continue
        return out


class HistoryReader:
    def __init__(self, design, y_up=False):
        self.design, self.y_up = design, y_up
        self.sketch_ids = {}
        self.sketches, self.features, self.notes = [], [], []

    def frame_of(self, component):
        """World placement of a component: identity for the root, its occurrence's transform when
        it is placed once (several copies: not rebuilt, their meshes stand in)."""
        root = self.design.rootComponent
        if component is None or token(component) == token(root):
            return Frame(None, self.y_up)
        occurrences = root.allOccurrencesByComponent(component)
        if occurrences.count != 1:
            return None
        occ = occurrences.item(0)
        matrix = getattr(occ, "transform2", None) or occ.transform
        return Frame(matrix, self.y_up)

    def read(self):
        timeline = self.design.timeline
        for i in range(timeline.count):
            item = timeline.item(i)
            try:
                if getattr(item, "isSuppressed", False) or getattr(item, "isRolledBack", False):
                    continue
                entity = item.entity
                k = kind(entity)
                if k == "Sketch":
                    self.read_sketch(entity)
                elif k in ("FilletFeature", "ChamferFeature", "ShellFeature"):
                    # Their input edges and faces exist only before them: the timeline is rolled
                    # back to just before the feature to read them, then forward again.
                    rolled = False
                    try:
                        item.rollTo(True)
                        rolled = True
                    except Exception:
                        pass
                    try:
                        self.read_feature(entity, k)
                    finally:
                        if rolled:
                            try:
                                timeline.moveToEnd()
                            except Exception:
                                pass
                elif k in ("ExtrudeFeature", "RevolveFeature", "HoleFeature"):
                    self.read_feature(entity, k)
                elif k in ("ConstructionPlane", "ConstructionAxis", "ConstructionPoint", "Occurrence", "JointOrigin",
                           "Joint", "AsBuiltJoint", "RigidGroup"):
                    continue
                else:
                    self.features.append({"type": k, "name": getattr(entity, "name", k)})
            except Exception:
                self.notes.append("%s: %s" % (getattr(item, "name", "?"), traceback.format_exc().splitlines()[-1]))
        return self.sketches, self.features

    def read_sketch(self, sketch):
        frame = self.frame_of(sketch.parentComponent)
        if frame is None:
            return
        sid = "S%d" % len(self.sketches)
        self.sketch_ids[token(sketch)] = (sid, frame)
        self.sketches.append(SketchReader(sketch, sid, frame, self.notes).read())

    def profile_key(self, profile):
        sketch = profile.parentSketch
        found = self.sketch_ids.get(token(sketch))
        if found is None:
            return None
        ps = sketch.profiles
        for i in range(ps.count):
            if token(ps.item(i)) == token(profile) or ps.item(i) == profile:
                return "%s/P%d" % (found[0], i)
        return None

    def profiles(self, entity):
        items = []
        try:
            if kind(entity) == "Profile":
                items = [entity]
            else:
                items = [entity.item(i) for i in range(entity.count)]
        except Exception:
            items = [entity]
        keys = []
        for p in items:
            if kind(p) != "Profile":
                return None                           # faces as profiles: not converted
            key = self.profile_key(p)
            if key is None:
                return None
            keys.append(key)
        return keys

    @staticmethod
    def operation(feature):
        try:
            import adsk.fusion
            ops = adsk.fusion.FeatureOperations
            return {ops.NewBodyFeatureOperation: "newBody", ops.JoinFeatureOperation: "join",
                    ops.CutFeatureOperation: "cut", ops.IntersectFeatureOperation: "intersect",
                    ops.NewComponentFeatureOperation: "newBody"}.get(feature.operation, "other")
        except Exception:
            return {0: "join", 1: "cut", 2: "intersect", 3: "newBody", 4: "newBody"}.get(feature.operation, "other")

    def read_feature(self, f, k):
        frame = self.frame_of(f.parentComponent)
        entry = {"type": k, "name": f.name}
        if frame is None:
            self.features.append(entry)
            return
        if k == "ExtrudeFeature":
            entry.update(type="extrude", operation=self.operation(f), profiles=self.profiles(f.profile))
            entry["extent"] = self.extent(f)
        elif k == "RevolveFeature":
            entry.update(type="revolve", operation=self.operation(f), profiles=self.profiles(f.profile))
            axis = f.axis
            if kind(axis) == "SketchLine" and self.sketch_ids.get(token(axis.parentSketch)):
                sid = self.sketch_ids[token(axis.parentSketch)][0]
                lines = axis.parentSketch.sketchCurves
                for i in range(lines.count):
                    if token(lines.item(i)) == token(axis):
                        entry["axis"] = {"curve": "c%d" % i, "sketch": sid}
            else:
                line = axis.geometry if kind(axis) != "BRepEdge" else axis.geometry.asInfiniteLine()
                entry["axis"] = {"origin": frame.point(line.origin), "direction": frame.vector(line.direction)}
            try:
                entry["angle"] = math.degrees(f.extentDefinition.angle.value)
            except Exception:
                entry["angle"] = 360.0
        elif k in ("FilletFeature", "ChamferFeature"):
            entry["type"] = "fillet" if k == "FilletFeature" else "chamfer"
            edges, size = [], None
            sets = f.edgeSets
            for i in range(sets.count):
                es = sets.item(i)
                param = getattr(es, "radius", None) or getattr(es, "distance", None)
                if param is None:
                    self.features.append({"type": kind(es), "name": f.name})
                    return
                if size is not None and abs(length_value(param) - size) > 1e-9:
                    self.features.append({"type": "fillet a raggi diversi", "name": f.name})
                    return
                size = length_value(param)
                ents = es.edges
                for j in range(ents.count):
                    e = ents.item(j)
                    if kind(e) != "BRepEdge":
                        continue
                    ev = e.evaluator
                    ok, t0, t1 = ev.getParameterExtents()
                    samples = []
                    for t in (t0, (t0 + t1) / 2, t1):
                        ok, p = ev.getPointAtParameter(t)
                        samples.append(frame.point(p))
                    edges.append(samples)
            entry.update(edges=edges, size=size)
        elif k == "HoleFeature":
            # Each drilled cylinder: from the far end, along its axis, as long as it is.
            centers, depth, direction, diameter = [], None, None, None
            for face in f.sideFaces:
                g = face.geometry
                if kind(g) != "Cylinder":
                    continue
                axis = g.axis
                n = math.sqrt(axis.x ** 2 + axis.y ** 2 + axis.z ** 2)
                ts = []
                for edge in face.edges:                 # its rims (a circle may have no vertex)
                    ev = edge.evaluator
                    ok, e0, e1 = ev.getParameterExtents()
                    for t in (e0, (e0 + e1) / 2, e1):
                        ok, q = ev.getPointAtParameter(t)
                        ts.append(((q.x - g.origin.x) * axis.x + (q.y - g.origin.y) * axis.y + (q.z - g.origin.z) * axis.z) / n)
                if not ts:
                    continue
                t1, t0 = max(ts), min(ts)

                class P:
                    pass
                top = P()
                top.x, top.y, top.z = (g.origin.x + axis.x / n * t1, g.origin.y + axis.y / n * t1, g.origin.z + axis.z / n * t1)
                down = P()
                down.x, down.y, down.z = -axis.x / n, -axis.y / n, -axis.z / n
                centers.append(frame.point(top))
                direction = frame.vector(down)
                depth = (t1 - t0) * CM
                diameter = 2 * g.radius * CM
            entry.update(type="hole", centers=centers, direction=direction, diameter=diameter, depth=depth)
        elif k == "ShellFeature":
            faces = []
            ents = f.inputEntities
            for i in range(ents.count):
                face = ents.item(i)
                if kind(face) != "BRepFace":
                    continue
                p = face.pointOnFace
                ok, normal = face.evaluator.getNormalAtPoint(p)
                faces.append([frame.point(p), frame.vector(normal)])
            entry.update(type="shell", faces=faces, size=length_value(f.insideThickness))
        self.features.append(entry)

    def extent(self, f):
        """How far the extrusion goes, parametric where Fusion says it (distance, symmetric,
        two sides, offset start), and in any case where it really starts and ends along the
        sketch's normal (measured on its start and end faces), so every extent comes in right."""
        try:
            info = self.extent_one(f)
            if getattr(f, "hasTwoExtents", False):
                info = {"type": "twoSides"}
                try:
                    d1, d2 = f.extentOne.distance, f.extentTwo.distance
                    info.update(distance=length_value(d1), expression=d1.expression,
                                distance2=length_value(d2), expression2=d2.expression)
                except Exception:
                    pass
            start = getattr(f, "startExtent", None)
            sk = kind(start) if start is not None else "NoneType"
            if sk == "OffsetStartDefinition":
                try:
                    off = start.offset
                    info.update(start=length_value(off), startExpression=getattr(off, "expression", None))
                except Exception:
                    info["startType"] = sk
            elif sk not in ("ProfilePlaneStartDefinition", "NoneType"):
                info["startType"] = sk
            measured = self.measure(f)
            if measured is not None:
                info.update(measuredStart=measured[0], measuredEnd=measured[1])
            return info
        except Exception:
            return {"type": "unknown"}

    def measure(self, f):
        """Where the extrusion starts and ends (mm along its sketch's normal, from the sketch)."""
        try:
            prof = f.profile
            p = prof if kind(prof) == "Profile" else prof.item(0)
            o, x, y, z = p.parentSketch.transform.getAsCoordinateSystem()
            n = math.sqrt(z.x ** 2 + z.y ** 2 + z.z ** 2)

            def along(faces):
                ts = []
                for i in range(faces.count):
                    q = faces.item(i).pointOnFace
                    ts.append(((q.x - o.x) * z.x + (q.y - o.y) * z.y + (q.z - o.z) * z.z) / n * CM)
                return sum(ts) / len(ts) if ts else None
            s, e = along(f.startFaces), along(f.endFaces)
            if s is None or e is None:
                return None
            return (s, e)
        except Exception:
            return None

    def extent_one(self, f):
        e = f.extentOne
        taper = 0.0
        try:
            taper = math.degrees(f.taperAngleOne.value)
        except Exception:
            pass
        ek = kind(e)
        if ek == "DistanceExtentDefinition":
            d = e.distance
            return {"type": "distance", "distance": length_value(d), "expression": d.expression, "taper": taper}
        if ek == "SymmetricExtentDefinition":
            d = e.distance
            full = getattr(e, "isFullLength", True)
            value = length_value(d) * (1 if full else 2)
            expression = d.expression if full else "2 * (%s)" % d.expression
            return {"type": "symmetric", "distance": value, "expression": expression, "taper": taper}
        if ek == "ThroughAllExtentDefinition":
            reversed_ = False
            try:
                import adsk.fusion
                reversed_ = e.direction == adsk.fusion.ExtentDirections.NegativeExtentDirection
            except Exception:
                pass
            return {"type": "through", "reversed": reversed_}
        return {"type": ek, "taper": taper}


def bodies_info(body, name, frame, mesh_index):
    """The finished body, to check the rebuilt one: volume (mm³) and extent (world, mm)."""
    try:
        volume = body.physicalProperties.volume * CM ** 3
        box = body.boundingBox
        corners = [frame.point(p) for p in _corners(box.minPoint, box.maxPoint)]
        lo = [min(c[i] for c in corners) for i in range(3)]
        hi = [max(c[i] for c in corners) for i in range(3)]
        return {"name": name, "volume": volume, "min": lo, "max": hi, "mesh": mesh_index}
    except Exception:
        return None


def _corners(a, b):
    class P:
        pass
    out = []
    for x in (a.x, b.x):
        for y in (a.y, b.y):
            for z in (a.z, b.z):
                p = P()
                p.x, p.y, p.z = x, y, z
                out.append(p)
    return out


def history(design, y_up, body_entries):
    """The `fusion` block: `body_entries` = [(body, name, mesh index)] in the .ftk's order
    (world-placed bodies, so their frame is only the Y-up turn)."""
    try:
        if getattr(design, "designType", 1) == 0:     # direct modelling: no history to rebuild
            return None
    except Exception:
        pass
    reader = HistoryReader(design, y_up)
    sketches, features = reader.read()
    world = Frame(None, y_up)
    bodies = [b for b in (bodies_info(body, name, world, i) for body, name, i in body_entries) if b]
    return {"version": 1, "parameters": parameters(design), "sketches": sketches, "features": features,
            "bodies": bodies, "notes": reader.notes}
