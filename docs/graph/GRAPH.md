# Grafo dei task

_Generato da `scripts/graph.py` — 2026-09-25 09:31. Non modificare a mano._

Legenda: verde = done · giallo = in corso · rosso = bloccato · grigio = da fare. Etichetta: `ID · titolo · agente`.

```mermaid
flowchart LR
  subgraph P0["0 · Coordinamento"]
    T00["T00 · Riconciliare scaffold doppio (core Vec3/indices, app SceneKit)<br/><i>claude</i>"]:::done
    T01["T01 · Archiviare file Codex pre-coordinamento in archive/codex-seed<br/><i>codex</i>"]:::in_progress
    T02["T02 · Mappa architetturale + report affidabilità<br/><i>codex</i>"]:::todo
  end
  subgraph P1["1 · Core"]
    T03["T03 · Validazione input + CADError nel core (porta test Codex)<br/><i>codex</i>"]:::todo
  end
  subgraph P2["2 · App"]
    T04["T04 · Undo/Redo sulla timeline<br/><i>claude</i>"]:::todo
    T05["T05 · Modalità schizzo 2D (polilinea/rettangolo/cerchio su XY)<br/><i>claude</i>"]:::todo
    T06["T06 · Estrusione da schizzo (profilo -> feature)<br/><i>claude</i>"]:::todo
    T07["T07 · Viewport Metal (sostituisce SceneKit deprecato)<br/><i>codex</i>"]:::todo
  end
  subgraph P3["3 · Modellazione"]
    T08["T08 · Booleane CSG (unione/sottrazione) su mesh<br/><i>claude</i>"]:::todo
    T09["T09 · Rivoluzione (revolve) di un profilo<br/><i>codex</i>"]:::todo
  end
  subgraph P4["4 · Stampa 3D"]
    T10["T10 · Export 3MF (zip + model XML in mm)<br/><i>codex</i>"]:::todo
    T11["T11 · Controllo stampabilità (chiusura, sbalzi, volume piatto)<br/><i>claude</i>"]:::todo
    T12["T12 · Piatto di stampa: appoggia, centra, dimensioni stampante<br/><i>any</i>"]:::todo
  end
  subgraph P5["5 · Qualità"]
    T13["T13 · Script CI locale (test core + build app)<br/><i>any</i>"]:::todo
    T14["T14 · Release 0.1 (icona, firma, .dmg)<br/><i>user</i>"]:::todo
  end
  T00 --> T02
  T00 --> T03
  T01 --> T03
  T00 --> T04
  T00 --> T05
  T05 --> T06
  T03 --> T06
  T00 --> T07
  T01 --> T07
  T03 --> T08
  T03 --> T09
  T03 --> T10
  T08 --> T11
  T07 --> T12
  T00 --> T13
  T06 --> T14
  T10 --> T14
  T11 --> T14
  T12 --> T14
  T13 --> T14
  classDef done fill:#2e7d32,color:#fff,stroke:#222
  classDef in_progress fill:#f9a825,color:#fff,stroke:#222
  classDef blocked fill:#c62828,color:#fff,stroke:#222
  classDef todo fill:#546e7a,color:#fff,stroke:#222
```

## Pronti da iniziare

- **T02** Mappa architetturale + report affidabilità — suggerito: codex
- **T04** Undo/Redo sulla timeline — suggerito: claude
- **T05** Modalità schizzo 2D (polilinea/rettangolo/cerchio su XY) — suggerito: claude
- **T13** Script CI locale (test core + build app) — suggerito: any

## Tabella

| ID | Titolo | Stato | Agente | Dipende da | File |
|---|---|---|---|---|---|
| T00 | Riconciliare scaffold doppio (core Vec3/indices, app SceneKit) | done | claude | — | Packages/CADCore<br>App/Sources<br>project.yml |
| T01 | Archiviare file Codex pre-coordinamento in archive/codex-seed | in_progress | codex | — | archive/codex-seed<br>App/TakeoffCADApp.swift<br>App/CADDocument.swift<br>App/EditorView.swift<br>App/SketchView.swift<br>App/MetalViewport.swift<br>App/CADShaders.metal |
| T02 | Mappa architetturale + report affidabilità | todo | codex | T00 | docs/architecture<br>scripts/architecture_graph.py |
| T03 | Validazione input + CADError nel core (porta test Codex) | todo | codex | T00, T01 | Packages/CADCore/Sources/CADCore/Validation.swift<br>Packages/CADCore/Tests/CADCoreTests/ValidationTests.swift |
| T04 | Undo/Redo sulla timeline | todo | claude | T00 | App/Sources/DesignModel.swift |
| T05 | Modalità schizzo 2D (polilinea/rettangolo/cerchio su XY) | todo | claude | T00 | App/Sources/Sketch |
| T06 | Estrusione da schizzo (profilo -> feature) | todo | claude | T05, T03 | App/Sources/Sketch<br>App/Sources/ContentView.swift |
| T07 | Viewport Metal (sostituisce SceneKit deprecato) | todo | codex | T00, T01 | App/Sources/Viewport |
| T08 | Booleane CSG (unione/sottrazione) su mesh | todo | claude | T03 | Packages/CADCore/Sources/CADCore/CSG.swift<br>Packages/CADCore/Tests/CADCoreTests/CSGTests.swift |
| T09 | Rivoluzione (revolve) di un profilo | todo | codex | T03 | Packages/CADCore/Sources/CADCore/Revolve.swift<br>Packages/CADCore/Tests/CADCoreTests/RevolveTests.swift |
| T10 | Export 3MF (zip + model XML in mm) | todo | codex | T03 | Packages/CADCore/Sources/CADCore/ThreeMF.swift<br>Packages/CADCore/Tests/CADCoreTests/ThreeMFTests.swift |
| T11 | Controllo stampabilità (chiusura, sbalzi, volume piatto) | todo | claude | T08 | Packages/CADCore/Sources/CADCore/Printability.swift |
| T12 | Piatto di stampa: appoggia, centra, dimensioni stampante | todo | any | T07 | App/Sources/Viewport |
| T13 | Script CI locale (test core + build app) | todo | any | T00 | scripts/ci.sh |
| T14 | Release 0.1 (icona, firma, .dmg) | todo | user | T06, T10, T11, T12, T13 | App/Resources<br>project.yml |
