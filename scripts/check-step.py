#!/usr/bin/env python3
"""Check STEP files with OpenCascade (the kernel of FreeCAD and many CAM programs).

Setup once:  python3.12 -m venv .occ && .occ/bin/pip install cadquery-ocp
Use:         .occ/bin/python scripts/check-step.py part.step [more.step ...]
Prints, per file: solids read, how many are invalid (BRepCheck), faces and total volume (mm3).
"""
import sys
from OCP.STEPControl import STEPControl_Reader
from OCP.IFSelect import IFSelect_RetDone
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.GProp import GProp_GProps
from OCP.BRepGProp import BRepGProp
from OCP.TopExp import TopExp_Explorer
from OCP.TopAbs import TopAbs_SOLID, TopAbs_FACE, TopAbs_SHELL
from OCP.TopoDS import TopoDS
from OCP.BRep import BRep_Tool
for path in sys.argv[1:]:
    r = STEPControl_Reader()
    st = r.ReadFile(path)
    if st != IFSelect_RetDone:
        print(path, "READ FAILED", st); continue
    r.TransferRoots()
    shape = r.OneShape()
    ex = TopExp_Explorer(shape, TopAbs_SOLID)
    solids = []
    while ex.More():
        solids.append(TopoDS.Solid(ex.Current())); ex.Next()
    total = 0
    bad = 0
    for s in solids:
        props = GProp_GProps(); BRepGProp.VolumeProperties_s(s, props)
        total += props.Mass()
        if not BRepCheck_Analyzer(s).IsValid(): bad += 1
    fex = TopExp_Explorer(shape, TopAbs_FACE); nf = 0
    while fex.More(): nf += 1; fex.Next()
    print(path.split('/')[-1], "solids", len(solids), "invalid", bad, "faces", nf, "volume %.3f" % total)
