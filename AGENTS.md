# AGENTS.md — regole di cooperazione Claude ↔ Codex

Questo repository è sviluppato da **due agenti AI in parallelo** (Claude Code e Codex) più
l'utente (Ross) che decide. Queste regole valgono per entrambi e hanno la precedenza
sulle abitudini di default di ciascun agente. `CLAUDE.md` rimanda a questo file.

## Prima di scrivere QUALSIASI file

1. `python3 scripts/graph.py status` — leggi il grafo dei task.
2. Leggi le ultime voci di `docs/COLLAB.md` (registro progressivo, append-only).
3. Scegli un task `todo` i cui prerequisiti sono `done`: `python3 scripts/graph.py next --agent <claude|codex>`.
4. **Reclamalo**: `python3 scripts/graph.py claim <ID> <claude|codex>`.
   Il claim fallisce se il task è già preso o se un altro task in corso possiede gli stessi file.
5. Tocca **solo** i file/cartelle elencati in `paths` del tuo task. Serve altro? Aggiungi una
   voce in `docs/COLLAB.md` e aggiorna `paths` (solo se nessun altro task attivo li possiede).

## Dopo

1. `swift test --package-path Packages/CADCore` e, se tocchi l'app, `scripts/build.sh` devono passare.
2. `python3 scripts/graph.py done <ID> --note "cosa è cambiato"` (aggiunge la voce al registro).
3. Se lasci lavoro a metà: `python3 scripts/graph.py handoff <ID> --note "stato, prossimo passo"`.
4. Commit piccoli, prefisso `[T##]` nel messaggio. Mai `git push --force`, mai riscrivere la storia.

## Ruoli (decisione dell'utente, 2026-09-25)

- **Claude = UX**: tutto ciò che l'utente vede e tocca — layout, viste SwiftUI, viewport e
  rendering, camera, selezione, schizzo a schermo, menu/scorciatoie, dialog, design system, onboarding.
- **Codex = funzionalità**: geometria e algoritmi (`CADCore`), modello dati e comandi
  dell'app (`App/Sources/Model`), undo/redo, file I/O, export, validazione, test, CI.
- Il resto si concorda nel registro. In caso di dubbio: se è *logica/dati* è di Codex, se è *presentazione/interazione* è di Claude.

## Confini di proprietà

| Area | Proprietario | Note |
|---|---|---|
| `Packages/CADCore/**` | codex | API pubbliche: cambiarle richiede una voce **DECISIONE** in COLLAB.md |
| `App/Sources/Model/**` (`DesignModel`, comandi, file) | codex | è il **contratto** con la UI |
| `App/Sources/UI/**` (viste, viewport, sketch UI) | claude | legge lo stato e chiama solo metodi di `DesignModel` |
| `project.yml`, `scripts/build.sh` | chi ha il task, uno alla volta | il `.xcodeproj` è **generato** (`xcodegen generate`), non modificarlo a mano |
| `scripts/ci.sh`, test | codex | |

### Contratto UI ↔ Model

- La UI non contiene logica geometrica e non modifica `document` direttamente se esiste un metodo
  del Model per farlo; il Model non importa viste SwiftUI.
- Se la UX ha bisogno di un'azione/dato che il Model non espone, Claude scrive in COLLAB.md
  una voce **RICHIESTA-API** con firma Swift proposta (es. `func addSketch(on plane: Plane) -> Sketch.ID`).
  Codex la implementa (o propone un'alternativa) e risponde nel registro. Nel frattempo Claude può
  lavorare con un mock locale in `App/Sources/UI/Previews/`, mai dentro `Model/`.
| `docs/COLLAB.md` | tutti, solo in append | non modificare voci altrui |
| `docs/graph/tasks.json` | tutti, solo tramite `scripts/graph.py` | |

## Convenzioni tecniche (vincolanti)

- Unità: **millimetri**. Asse **Z verso l'alto** (come gli slicer). Il viewport converte.
- Mesh: triangoli CCW visti dall'esterno (normali uscenti); ogni solido esportato deve essere chiuso (watertight).
- Il core (`CADCore`) non importa AppKit/SwiftUI/SceneKit/Metal: deve restare testabile con `swift test`.
- Swift 6, macOS 14+. Progetto Xcode generato da `project.yml` con XcodeGen.
- Lingua UI: italiano. Codice e identificatori: inglese.

## Conflitti

Se trovi file modificati da un altro agente fuori dal tuo task: **non sovrascriverli**.
Scrivi una voce `CONFLITTO` in `docs/COLLAB.md` e fermati su quel file finché l'utente o
il proprietario non risponde.
