import CADCore
import Foundation

/// Sposta, Ruota and Copia/Incolla in the sketch editor (geometry in CADCore's SketchTransform).
extension SketchSession {
    /// Sposta: the selected entity follows the point clicked first to the one clicked second.
    /// The constraints follow it; when they cannot, the move is refused with a notice.
    func moveClick(_ p: Vec2) {
        guard let id = transformTarget(p) else { return }
        guard let from = moveFrom else {
            moveFrom = p
            notice = String(localized: "Ora clicca dove portarla.")
            return
        }
        guard dist(from, p) > 1e-6 else { return }
        applyTransform(id, rotating: 0, around: Vec2(0, 0), moving: p - from)
        moveFrom = nil
    }

    /// Ruota: the selected entity turns around the point clicked first by the angle read from
    /// the centre to the point clicked second (counter-clockwise).
    func rotateClick(_ p: Vec2) {
        guard let id = transformTarget(p) else { return }
        guard let center = rotateCenter else {
            rotateCenter = p
            notice = String(localized: "Ora clicca un punto: l'angolo è quello da lì.")
            return
        }
        guard dist(center, p) > 1e-6 else { return }
        applyTransform(id, rotating: atan2(p.y - center.y, p.x - center.x), around: center, moving: Vec2(0, 0))
        rotateCenter = nil
    }

    /// The entity to transform: the selected one, or the one under the click (so a move works
    /// even before selecting). Off-plane entities have no place in the plane's transform.
    private func transformTarget(_ p: Vec2) -> SketchShape.ID? {
        guard let id = selection ?? pick(p), let s = shape(id) else {
            notice = String(localized: "Seleziona un'entità 2D da spostare o ruotare.")
            return nil
        }
        guard !s.is3D else {
            notice = String(localized: "Le entità 3D non si spostano nel piano dello schizzo.")
            return nil
        }
        selection = id
        return id
    }

    private func applyTransform(_ id: SketchShape.ID, rotating angle: Double, around center: Vec2, moving delta: Vec2) {
        var next = sketch
        guard next.transform([id], rotating: angle, around: center, moving: delta) else {
            notice = String(localized: "I vincoli impediscono lo spostamento: togli un vincolo o una quota che lo blocca.")
            return
        }
        notice = nil
        sketch = next
    }

    /// Keeps the selected entity for ⌘V (the copy gets a fresh ID and no constraints).
    @discardableResult
    func copySelection() -> Bool {
        guard let id = selection, let s = shape(id), !s.is3D else {
            notice = String(localized: "Seleziona un'entità 2D da copiare.")
            return false
        }
        copiedShapes = [s]
        notice = String(localized: "Copiata: ⌘V per incollarla.")
        return true
    }

    /// Pastes the copied entities with their first point where `target` says, else under the
    /// cursor, else a little to the right (so the copy does not hide the original).
    func paste(at target: Vec2? = nil) {
        guard let first = copiedShapes.first, let base = first.point(0) else {
            notice = String(localized: "Non c'è nulla da incollare: copia un'entità con ⌘C.")
            return
        }
        let to = target ?? cursor ?? (base + Vec2(10, 0))
        var next = sketch
        let made = next.insert(copies: copiedShapes, moving: to - base)
        sketch = next
        selection = made.last
        notice = nil
    }
}
