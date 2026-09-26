"""Fusion 360 script: «Importa progetto in CAD Takeoff».

Exports every design of a Fusion project (all folders, recursively) as CAD Takeoff designs
(.ftk) into <library>/<project>/<same folders>/<design>.ftk. Each visible solid body (root and
components, placed as in the assembly) becomes an imported mesh in millimetres with its name and
colour, as the «Esporta per CAD Takeoff» add-in does for one design.

Designs already exported and not changed since in Fusion are skipped, so the script can be run
again after editing a few parts. Documents opened here are closed without saving. A log of what
was exported, skipped or failed is written next to the designs (import-fusion.txt).
"""
import adsk.core
import adsk.fusion
import base64
import datetime
import json
import os
import re
import struct
import traceback
import uuid

DEFAULT_PROJECT = "025 RobotVolley"
DEFAULT_LIBRARY = os.path.expanduser("~/Documents/DRAW")


def safe(name):
    return re.sub(r'[\\/:*?"<>|]+', "-", name).strip() or "Senza nome"


def body_colour(body):
    try:
        appearance = body.appearance
        for name in ("Color", "Colore", "Generic Color"):
            prop = appearance.appearanceProperties.itemByName(name)
            if prop:
                value = adsk.core.ColorProperty.cast(prop).value
                return {"red": value.red, "green": value.green, "blue": value.blue}
        for i in range(appearance.appearanceProperties.count):
            prop = adsk.core.ColorProperty.cast(appearance.appearanceProperties.item(i))
            if prop and prop.value:
                return {"red": prop.value.red, "green": prop.value.green, "blue": prop.value.blue}
    except Exception:
        pass
    return {"red": 138, "green": 150, "blue": 163}


def y_up(app):
    try:
        return app.preferences.generalPreferences.defaultModelingOrientation == \
            adsk.core.DefaultModelingOrientations.YUpModelingOrientation
    except Exception:
        return False


def mesh_feature(body, name, source, rotate_y_up):
    calculator = body.meshManager.createMeshCalculator()
    calculator.setQuality(adsk.fusion.TriangleMeshQualityOptions.HighQualityTriangleMesh)
    mesh = calculator.calculate()
    coords = mesh.nodeCoordinatesAsDouble          # centimetres
    floats = []
    for i in range(0, len(coords), 3):
        x, y, z = coords[i] * 10, coords[i + 1] * 10, coords[i + 2] * 10
        if rotate_y_up:
            x, y, z = x, -z, y
        floats += [x, y, z]
    indices = mesh.nodeIndices
    return {
        "id": str(uuid.uuid4()).upper(),
        "name": name,
        "kind": {"importedMesh": {"_0": {
            "positions": base64.b64encode(struct.pack("<%df" % len(floats), *floats)).decode("ascii"),
            "indices": base64.b64encode(struct.pack("<%dI" % len(indices), *indices)).decode("ascii"),
            "source": source,
        }}},
        "position": {"x": 0, "y": 0, "z": 0},
        "isVisible": True,
        "color": body_colour(body),
        "operation": "newBody",
    }


def export_active(app, path, source):
    design = adsk.fusion.Design.cast(app.activeProduct)
    if not design:
        raise RuntimeError("non è un disegno 3D")
    rotate = y_up(app)
    features = []
    root = design.rootComponent
    for body in root.bRepBodies:
        if body.isVisible and body.isSolid:
            features.append(mesh_feature(body, body.name, source, rotate))
    for occurrence in root.allOccurrences:
        if not occurrence.isLightBulbOn:
            continue
        for body in occurrence.bRepBodies:          # proxies: already placed in the assembly
            if body.isVisible and body.isSolid:
                features.append(mesh_feature(body, occurrence.name + " · " + body.name, source, rotate))
    if not features:
        raise RuntimeError("nessun corpo solido visibile")
    doc = {"version": 2, "timeline": [{"content": {"feature": {"_0": f}}, "isSuppressed": False} for f in features]}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f)
    return len(features)


def find_root(app, name):
    """(name, DataFolder) of a project or of a folder inside a project with this name: exact
    name first, then ignoring case, spaces and punctuation, then containing it. Fusion users
    often keep one project per team with a folder per job (e.g. «BtRoss Projects › 025 …»)."""
    def key(text):
        return re.sub(r"[^a-z0-9]", "", text.lower())
    wanted = key(name)
    found = {"exact": None, "same": None, "loose": None}

    def consider(label, folder):
        if label.strip() == name.strip() and not found["exact"]:
            found["exact"] = (label, folder)
        elif key(label) == wanted and not found["same"]:
            found["same"] = (label, folder)
        elif wanted and wanted in key(label) and not found["loose"]:
            found["loose"] = (label, folder)

    for h in range(app.data.dataHubs.count):
        hub = app.data.dataHubs.item(h)
        for p in range(hub.dataProjects.count):
            project = hub.dataProjects.item(p)
            consider(project.name, project.rootFolder)
            if found["exact"]:
                return found["exact"]
            # Folders two levels down inside each project.
            stack = [(project.rootFolder, 0)]
            while stack:
                folder, depth = stack.pop()
                for i in range(folder.dataFolders.count):
                    sub = folder.dataFolders.item(i)
                    consider(sub.name, sub)
                    if found["exact"]:
                        return found["exact"]
                    if depth < 1:
                        stack.append((sub, depth + 1))
    return found["same"] or found["loose"]


def designs(folder, parts):
    """(folder path parts, dataFile) for every Fusion design under `folder`."""
    for i in range(folder.dataFiles.count):
        data = folder.dataFiles.item(i)
        if data.fileExtension in ("f3d", "f3z"):
            yield parts, data
    for i in range(folder.dataFolders.count):
        sub = folder.dataFolders.item(i)
        yield from designs(sub, parts + [safe(sub.name)])


def run(context):
    app = adsk.core.Application.get()
    ui = app.userInterface
    try:
        answer, cancelled = ui.inputBox("Progetto Fusion da importare in CAD Takeoff:", "CAD Takeoff", DEFAULT_PROJECT)
        if cancelled:
            return
        root = find_root(app, answer)
        if not root:
            ui.messageBox("Né un progetto né una cartella «%s» negli hub di Fusion." % answer, "CAD Takeoff")
            return
        name, root_folder = root
        library, cancelled = ui.inputBox("Cartella dei progetti di CAD Takeoff:", "CAD Takeoff", DEFAULT_LIBRARY)
        if cancelled:
            return
        target = os.path.join(os.path.expanduser(library), safe(name))
        progress = ui.createProgressDialog()
        progress.show("CAD Takeoff", "Leggo le cartelle di «%s»…" % name, 0, 1, 0)
        adsk.doEvents()
        files = list(designs(root_folder, []))
        progress.hide()
        progress = ui.createProgressDialog()
        progress.cancelButtonText = "Interrompi"
        progress.isBackgroundTranslucent = False
        progress.show("CAD Takeoff", "Importo %v di %m: %p%", 0, max(1, len(files)), 0)
        log, exported, skipped, failed = [], 0, 0, 0
        for n, (parts, data) in enumerate(files):
            if progress.wasCancelled:
                log.append("Interrotto dall'utente.")
                break
            progress.progressValue = n
            progress.message = "%s (%d di %d)" % (data.name, n + 1, len(files))
            adsk.doEvents()
            path = os.path.join(target, *parts, safe(data.name) + ".ftk")
            label = "/".join(parts + [data.name])
            try:
                changed = data.dateModified   # seconds since epoch
                if os.path.exists(path) and os.path.getmtime(path) >= changed:
                    skipped += 1
                    log.append("uguale    " + label)
                    continue
            except Exception:
                pass
            document = None
            try:
                document = app.documents.open(data, True)
                count = export_active(app, path, data.name + "." + data.fileExtension)
                exported += 1
                log.append("esportato %s (%d corpi)" % (label, count))
            except Exception as error:
                failed += 1
                log.append("ERRORE    %s: %s" % (label, error))
            finally:
                if document:
                    try:
                        document.close(False)
                    except Exception:
                        pass
        progress.hide()
        os.makedirs(target, exist_ok=True)
        with open(os.path.join(target, "import-fusion.txt"), "w", encoding="utf-8") as f:
            f.write("Importazione da Fusion: %s — %s\n\n" % (name, datetime.datetime.now().strftime("%Y-%m-%d %H:%M")))
            f.write("\n".join(log) + "\n")
        ui.messageBox("Progetto «%s»:\n%d disegni esportati, %d già aggiornati, %d non riusciti.\n\nCartella: %s\n"
                      "(dettagli in import-fusion.txt)" % (name, exported, skipped, failed, target), "CAD Takeoff")
    except Exception:
        ui.messageBox("Importazione non riuscita:\n" + traceback.format_exc(), "CAD Takeoff")
