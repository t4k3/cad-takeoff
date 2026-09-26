"""Fusion 360 add-in: «Esporta per Fusion Takeoff».

Writes the active design as a Fusion Takeoff design (.ftk) in a chosen folder — usually a
project folder of the Fusion Takeoff library — on demand or every time the design is saved.

Each visible body (root and components, already placed in the assembly) becomes an imported
mesh in millimetres, with its name and appearance colour. Parametric history (sketches,
extrusions…) is not converted yet: in Fusion Takeoff the flat faces of the bodies are real
faces, so holes, rounds and sketches can be added on top.
"""
import adsk.core
import adsk.fusion
import base64
import json
import os
import re
import struct
import traceback
import uuid

CMD_ID = "FusionTakeoffExport"
PANEL_ID = "SolidScriptsAddinsPanel"
SETTINGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "settings.json")
handlers = []


def load_settings():
    try:
        with open(SETTINGS, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_settings(values):
    try:
        with open(SETTINGS, "w", encoding="utf-8") as f:
            json.dump(values, f, indent=2)
    except Exception:
        pass


def body_colour(body):
    """Appearance colour as 0–255 RGB, grey when unknown."""
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
    """Fusion designs can be Y-up; Fusion Takeoff (like slicers) is Z-up."""
    try:
        orientation = app.preferences.generalPreferences.defaultModelingOrientation
        return orientation == adsk.core.DefaultModelingOrientations.YUpModelingOrientation
    except Exception:
        return False


def mesh_feature(body, name, source, rotate_y_up):
    calculator = body.meshManager.createMeshCalculator()
    calculator.setQuality(adsk.fusion.TriangleMeshQualityOptions.HighQualityTriangleMesh)
    mesh = calculator.calculate()
    coords = mesh.nodeCoordinatesAsDouble          # centimetres
    indices = mesh.nodeIndices
    floats = []
    for i in range(0, len(coords), 3):
        x, y, z = coords[i] * 10, coords[i + 1] * 10, coords[i + 2] * 10
        if rotate_y_up:
            x, y, z = x, -z, y
        floats += [x, y, z]
    positions = struct.pack("<%df" % len(floats), *floats)
    packed = struct.pack("<%dI" % len(indices), *indices)
    return {
        "id": str(uuid.uuid4()).upper(),
        "name": name,
        "kind": {"importedMesh": {"_0": {
            "positions": base64.b64encode(positions).decode("ascii"),
            "indices": base64.b64encode(packed).decode("ascii"),
            "source": source,
        }}},
        "position": {"x": 0, "y": 0, "z": 0},
        "isVisible": True,
        "color": body_colour(body),
        "operation": "newBody",
    }


def export_design(app, folder):
    design = adsk.fusion.Design.cast(app.activeProduct)
    if not design:
        raise RuntimeError("Apri un disegno (area di lavoro Progettazione) prima di esportare.")
    document = app.activeDocument
    title = document.name if document else "Disegno"
    source = title + ".f3d"
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
        raise RuntimeError("Nessun corpo solido visibile da esportare.")
    doc = {"version": 2, "timeline": [{"content": {"feature": {"_0": f}}, "isSuppressed": False} for f in features]}
    safe = re.sub(r'[\\/:*?"<>|]+', "-", title).strip() or "Disegno"
    path = os.path.join(folder, safe + ".ftk")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f)
    return path, len(features)


def choose_folder(ui, current):
    dialog = ui.createFolderDialog()
    dialog.title = "Cartella dove salvare i disegni per Fusion Takeoff (es. un progetto della libreria)"
    if current:
        dialog.initialDirectory = current
    if dialog.showDialog() == adsk.core.DialogResults.DialogOK:
        return dialog.folder
    return None


class ExecuteHandler(adsk.core.CommandEventHandler):
    def notify(self, args):
        app = adsk.core.Application.get()
        try:
            inputs = args.command.commandInputs
            settings = load_settings()
            settings["auto"] = adsk.core.BoolValueCommandInput.cast(inputs.itemById("auto")).value
            folder = settings.get("folder")
            if not folder or not os.path.isdir(folder):
                folder = choose_folder(app.userInterface, folder)
                if not folder:
                    return
                settings["folder"] = folder
            save_settings(settings)
            path, count = export_design(app, folder)
            app.userInterface.messageBox("Esportati %d corpi in:\n%s\n\nIn Fusion Takeoff: Home › apri il disegno." % (count, path),
                                         "Fusion Takeoff")
        except Exception as error:
            app.userInterface.messageBox("Esportazione non riuscita:\n%s" % error, "Fusion Takeoff")


class InputChangedHandler(adsk.core.InputChangedEventHandler):
    def notify(self, args):
        if args.input.id != "choose":
            return
        app = adsk.core.Application.get()
        settings = load_settings()
        folder = choose_folder(app.userInterface, settings.get("folder"))
        if folder:
            settings["folder"] = folder
            save_settings(settings)
            text = adsk.core.TextBoxCommandInput.cast(args.inputs.itemById("folder"))
            if text:
                text.text = folder


class CommandCreatedHandler(adsk.core.CommandCreatedEventHandler):
    def notify(self, args):
        cmd = args.command
        settings = load_settings()
        inputs = cmd.commandInputs
        inputs.addTextBoxCommandInput("folder", "Cartella", settings.get("folder", "(da scegliere)"), 2, True)
        inputs.addBoolValueInput("choose", "Scegli cartella…", False, "", False)
        inputs.addBoolValueInput("auto", "Esporta a ogni salvataggio", True, "", bool(settings.get("auto", False)))
        cmd.okButtonText = "Esporta"
        for event, handler in ((cmd.execute, ExecuteHandler()), (cmd.inputChanged, InputChangedHandler())):
            event.add(handler)
            handlers.append(handler)


class DocumentSavedHandler(adsk.core.DocumentEventHandler):
    def notify(self, args):
        settings = load_settings()
        if not settings.get("auto") or not settings.get("folder"):
            return
        try:
            export_design(adsk.core.Application.get(), settings["folder"])
        except Exception:
            pass   # silent on save: the explicit command reports errors


def run(context):
    app = adsk.core.Application.get()
    ui = app.userInterface
    try:
        definition = ui.commandDefinitions.itemById(CMD_ID) or ui.commandDefinitions.addButtonDefinition(
            CMD_ID, "Esporta per Fusion Takeoff", "Salva il disegno attivo come .ftk per Fusion Takeoff (millimetri, Z in alto)", "")
        created = CommandCreatedHandler()
        definition.commandCreated.add(created)
        handlers.append(created)
        panel = ui.allToolbarPanels.itemById(PANEL_ID)
        if panel and not panel.controls.itemById(CMD_ID):
            panel.controls.addCommand(definition)
        saved = DocumentSavedHandler()
        app.documentSaved.add(saved)
        handlers.append(saved)
    except Exception:
        ui.messageBox("Fusion Takeoff: avvio add-in non riuscito\n" + traceback.format_exc())


def stop(context):
    ui = adsk.core.Application.get().userInterface
    try:
        panel = ui.allToolbarPanels.itemById(PANEL_ID)
        control = panel.controls.itemById(CMD_ID) if panel else None
        if control:
            control.deleteMe()
        definition = ui.commandDefinitions.itemById(CMD_ID)
        if definition:
            definition.deleteMe()
    except Exception:
        pass
