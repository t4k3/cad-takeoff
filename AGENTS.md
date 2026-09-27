# AGENTS.md — regole di cooperazione Claude ↔ Codex

Questo repository è sviluppato da **due agenti AI in parallelo** (Claude Code e Codex) più
l'utente (Ross) che decide. Queste regole valgono per entrambi e hanno la precedenza
sulle abitudini di default di ciascun agente. `CLAUDE.md` rimanda a questo file.

## Prima di scrivere QUALSIASI file

1. `python3 scripts/graph.py status` — leggi il grafo dei task.
2. Leggi le ultime voci di `docs/COLLAB.md` (registro progressivo, append-only).
3. Se il tuo lavoro finisce davanti all'utente (UI) o la UI lo userà (API di un motore), leggi
   **`docs/UX_RULES.md`**: regole vincolanti, compreso il §6 «Cosa deve dare un motore alla UI».
4. Scegli un task `todo` i cui prerequisiti sono `done`: `python3 scripts/graph.py next --agent <claude|codex>`.
5. **Reclamalo**: `python3 scripts/graph.py claim <ID> <claude|codex>`.
   Il claim fallisce se il task è già preso o se un altro task in corso possiede gli stessi file.
6. Tocca **solo** i file/cartelle elencati in `paths` del tuo task. Serve altro? Aggiungi una
   voce in `docs/COLLAB.md` e aggiorna `paths` (solo se nessun altro task attivo li possiede).

## Dopo

1. `swift test --package-path Packages/CADCore` e, se tocchi l'app, `scripts/build.sh` devono passare.
2. `python3 scripts/graph.py done <ID> --note "cosa è cambiato"` (aggiunge la voce al registro).
3. Se lasci lavoro a metà: `python3 scripts/graph.py handoff <ID> --note "stato, prossimo passo"`.
4. Commit piccoli, prefisso `[T##]` nel messaggio. Mai `git push --force`, mai riscrivere la storia.
5. **Metti nel commit solo i percorsi del tuo task** (`git add <percorsi>`; mai `git add -A` o
   `git commit -a`): l'altro agente può avere lavoro a metà nello stesso albero.

## Ruoli (decisione dell'utente, 2026-09-27 — sostituisce quella del 25/09)

- **Claude = CAD e app**: tutto CADCore, il Model dell'app, la UI, la CI e la build; per
  l'elettronica la **UX** (schede Schema/PCB, editor, verifiche a schermo) e l'**aggancio** del motore
  all'app (package nel progetto Xcode, ponte `App/Sources/Model/Electronics`, documento elettronico
  nel progetto/Home, strumenti assistente/MCP, test elettronica nella CI).
- **Codex = motore elettronico**: `Packages/ElectronicsCore` (e i futuri package elettronici puri),
  formati, validazioni, routing/DRC/Gerber, `docs/electronics`, `Tests/Electronics`,
  `scripts/test-electronics.sh`. Espone alla UI quanto chiede `docs/UX_RULES.md` §6; non tocca
  `App/**`, `Packages/CADCore/**`, `project.yml`, `scripts/ci.sh`.
- Per ciò che serve all'altro: voce **RICHIESTA-API** in `docs/COLLAB.md` con firma proposta.

### Ruoli precedenti (25/09, per la storia)

- **Claude = UX**: tutto ciò che l'utente vede e tocca — layout, viste SwiftUI, viewport e
  rendering, camera, selezione, schizzo a schermo, menu/scorciatoie, dialog, design system, onboarding.
- **Codex = funzionalità**: geometria e algoritmi (`CADCore`), modello dati e comandi
  dell'app (`App/Sources/Model`), undo/redo, file I/O, export, validazione, test, CI.
- Il resto si concorda nel registro. In caso di dubbio: se è *logica/dati* è di Codex, se è *presentazione/interazione* è di Claude.

## Confini di proprietà

| Area | Proprietario | Note |
|---|---|---|
| `Packages/CADCore/**` | claude | dal 26/09 |
| `App/Sources/Model/**`, `App/Sources/UI/**`, `App/Sources/Integration/**` | claude | compresi `Model/Electronics` e `UI/Electronics` (aggancio e UX elettronica) |
| `project.yml`, `scripts/build.sh`, `scripts/ci.sh`, `.githooks/**` | claude | il `.xcodeproj` è **generato** (`xcodegen generate`), non modificarlo a mano |
| `Packages/ElectronicsCore/**`, `docs/electronics/**`, `Tests/Electronics/**`, `scripts/test-electronics.sh` | codex | API pubbliche: cambiarle richiede una voce **DECISIONE** in COLLAB.md (la UI le usa) |
| `docs/UX_RULES.md` | claude, su decisione di Ross | vincolante per tutti |
| `docs/COLLAB.md` | tutti, solo in append | non modificare voci altrui |
| `docs/graph/tasks.json` | tutti, solo tramite `scripts/graph.py` | |

### Contratto motore ↔ app

- Il motore (package puro) non importa AppKit/SwiftUI/Metal né CADCore se non concordato; l'app
  non ricalcola geometria o regole del motore (pin-map, trasformazioni, DRC…): le chiama.
- Il motore espone ciò che chiede `docs/UX_RULES.md` §6 (comandi transazionali, anteprima,
  primitive da disegnare, pick/snap per ID, diagnostica con soggetti).
- Se all'aggancio serve un'azione/dato che il motore non espone, Claude scrive in COLLAB.md una
  voce **RICHIESTA-API** con firma Swift proposta; Codex la implementa (o propone un'alternativa) e
  risponde nel registro. Nel frattempo Claude lavora con un adattatore locale in
  `App/Sources/Model/Electronics`, mai dentro il package di Codex.

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
