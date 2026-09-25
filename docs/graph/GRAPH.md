# Grafo dei task

_Generato da `scripts/graph.py` — 2026-09-25 09:45. Non modificare a mano._

Legenda: verde = done · giallo = in corso · rosso = bloccato · grigio = da fare. Etichetta: `ID · titolo · agente`.

```mermaid
flowchart LR
  subgraph P0["0 · Coordinamento"]
    T00["T00 · Riconciliare scaffold doppio (core Vec3/indices, app SceneKit)<br/><i>claude</i>"]:::done
    T01["T01 · Archiviare file Codex pre-coordinamento in archive/codex-seed<br/><i>codex</i>"]:::done
    T02["T02 · Mappa architetturale + report affidabilità<br/><i>codex</i>"]:::done
    T16["T16 · Separare App/Sources in Model/ (codex) e UI/ (claude) + fix build.sh<br/><i>claude</i>"]:::done
  end
  subgraph P1["1 · Core"]
    T03["T03 · Validazione input + CADError nel core (porta test Codex)<br/><i>codex</i>"]:::todo
    T15["T15 · Modello schizzo nel core (entità, profili chiusi, vincoli base)<br/><i>codex</i>"]:::todo
  end
  subgraph P2["2 · App"]
    T04["T04 · Undo/Redo sulla timeline<br/><i>codex</i>"]:::todo
    T05["T05 · Modalità schizzo 2D (polilinea/rettangolo/cerchio su XY)<br/><i>claude</i>"]:::todo
    T06["T06 · Estrusione da schizzo (profilo -> feature)<br/><i>codex</i>"]:::todo
    T07["T07 · Viewport Metal (sostituisce SceneKit deprecato)<br/><i>claude</i>"]:::todo
  end
  subgraph P3["3 · Modellazione"]
    T08["T08 · Booleane CSG (unione/sottrazione) su mesh<br/><i>codex</i>"]:::todo
    T09["T09 · Rivoluzione (revolve) di un profilo<br/><i>codex</i>"]:::todo
  end
  subgraph P4["4 · Stampa 3D"]
    T10["T10 · Export 3MF (zip + model XML in mm)<br/><i>codex</i>"]:::todo
    T11["T11 · Controllo stampabilità (chiusura, sbalzi, volume piatto)<br/><i>codex</i>"]:::todo
    T12["T12 · Piatto di stampa: appoggia, centra, dimensioni stampante<br/><i>codex</i>"]:::todo
    T21["T21 · Piatto di stampa a schermo (volume stampante, oggetto appoggiato)<br/><i>claude</i>"]:::todo
    T22["T22 · Pannello stampabilità: report visivo, evidenzia problemi<br/><i>claude</i>"]:::todo
    T23["T23 · Dialog di esportazione STL/3MF (formato, risoluzione, anteprima)<br/><i>claude</i>"]:::todo
  end
  subgraph P5["5 · Qualità"]
    T13["T13 · Script CI locale (test core + build app)<br/><i>codex</i>"]:::todo
    T14["T14 · Release 0.1 (icona, firma, .dmg)<br/><i>user</i>"]:::todo
  end
  subgraph P6["2 · UX"]
    T17["T17 · Workspace stile Fusion: toolbar a schede, browser, timeline in basso, design system<br/><i>claude</i>"]:::done
    T18["T18 · ViewCube + navigazione camera (orbita/pan/zoom, viste standard)<br/><i>claude</i>"]:::todo
    T19["T19 · Selezione ed evidenziazione nel viewport (picking)<br/><i>claude</i>"]:::todo
    T20["T20 · Comandi, menu, scorciatoie, stati vuoti, onboarding<br/><i>claude</i>"]:::todo
  end
  T00 --> T02
  T00 --> T03
  T01 --> T03
  T16 --> T04
  T16 --> T05
  T05 --> T06
  T15 --> T06
  T03 --> T06
  T16 --> T07
  T03 --> T08
  T03 --> T09
  T03 --> T10
  T08 --> T11
  T03 --> T12
  T00 --> T13
  T06 --> T14
  T20 --> T14
  T21 --> T14
  T22 --> T14
  T23 --> T14
  T13 --> T14
  T03 --> T15
  T00 --> T16
  T16 --> T17
  T07 --> T18
  T07 --> T19
  T17 --> T20
  T04 --> T20
  T07 --> T21
  T12 --> T21
  T11 --> T22
  T19 --> T22
  T10 --> T23
  T17 --> T23
  classDef done fill:#2e7d32,color:#fff,stroke:#222
  classDef in_progress fill:#f9a825,color:#fff,stroke:#222
  classDef blocked fill:#c62828,color:#fff,stroke:#222
  classDef todo fill:#546e7a,color:#fff,stroke:#222
```

## Pronti da iniziare

- **T03** Validazione input + CADError nel core (porta test Codex) — suggerito: codex
- **T04** Undo/Redo sulla timeline — suggerito: codex
- **T05** Modalità schizzo 2D (polilinea/rettangolo/cerchio su XY) — suggerito: claude
- **T07** Viewport Metal (sostituisce SceneKit deprecato) — suggerito: claude
- **T13** Script CI locale (test core + build app) — suggerito: codex

## Tabella

| ID | Titolo | Stato | Agente | Dipende da | File |
|---|---|---|---|---|---|
| T00 | Riconciliare scaffold doppio (core Vec3/indices, app SceneKit) | done | claude | — | Packages/CADCore<br>App/Sources<br>project.yml |
| T01 | Archiviare file Codex pre-coordinamento in archive/codex-seed | done | codex | — | archive/codex-seed<br>App/TakeoffCADApp.swift<br>App/CADDocument.swift<br>App/EditorView.swift<br>App/SketchView.swift<br>App/MetalViewport.swift<br>App/CADShaders.metal |
| T02 | Mappa architetturale + report affidabilità | done | codex | T00 | docs/architecture<br>scripts/architecture_graph.py |
| T03 | Validazione input + CADError nel core (porta test Codex) | todo | codex | T00, T01 | Packages/CADCore/Sources/CADCore<br>Packages/CADCore/Tests/CADCoreTests |
| T04 | Undo/Redo sulla timeline | todo | codex | T16 | App/Sources/Model |
| T05 | Modalità schizzo 2D (polilinea/rettangolo/cerchio su XY) | todo | claude | T16 | App/Sources/UI/Sketch |
| T06 | Estrusione da schizzo (profilo -> feature) | todo | codex | T05, T15, T03 | App/Sources/Model<br>Packages/CADCore/Sources/CADCore/Document.swift |
| T07 | Viewport Metal (sostituisce SceneKit deprecato) | todo | claude | T16 | App/Sources/UI/Viewport |
| T08 | Booleane CSG (unione/sottrazione) su mesh | todo | codex | T03 | Packages/CADCore/Sources/CADCore/CSG.swift<br>Packages/CADCore/Tests/CADCoreTests/CSGTests.swift |
| T09 | Rivoluzione (revolve) di un profilo | todo | codex | T03 | Packages/CADCore/Sources/CADCore/Revolve.swift<br>Packages/CADCore/Tests/CADCoreTests/RevolveTests.swift |
| T10 | Export 3MF (zip + model XML in mm) | todo | codex | T03 | Packages/CADCore/Sources/CADCore/ThreeMF.swift<br>Packages/CADCore/Tests/CADCoreTests/ThreeMFTests.swift |
| T11 | Controllo stampabilità (chiusura, sbalzi, volume piatto) | todo | codex | T08 | Packages/CADCore/Sources/CADCore/Printability.swift |
| T12 | Piatto di stampa: appoggia, centra, dimensioni stampante | todo | codex | T03 | Packages/CADCore/Sources/CADCore/Placement.swift<br>Packages/CADCore/Tests/CADCoreTests/PlacementTests.swift |
| T13 | Script CI locale (test core + build app) | todo | codex | T00 | scripts/ci.sh |
| T14 | Release 0.1 (icona, firma, .dmg) | todo | user | T06, T20, T21, T22, T23, T13 | App/Resources<br>project.yml |
| T15 | Modello schizzo nel core (entità, profili chiusi, vincoli base) | todo | codex | T03 | Packages/CADCore/Sources/CADCore/SketchModel.swift<br>Packages/CADCore/Tests/CADCoreTests/SketchModelTests.swift |
| T16 | Separare App/Sources in Model/ (codex) e UI/ (claude) + fix build.sh | done | claude | T00 | App/Sources<br>scripts/build.sh<br>project.yml |
| T17 | Workspace stile Fusion: toolbar a schede, browser, timeline in basso, design system | done | claude | T16 | App/Sources/UI/Workspace<br>App/Sources/UI/DesignSystem<br>App/Sources/UI/FusionTakeoffApp.swift |
| T18 | ViewCube + navigazione camera (orbita/pan/zoom, viste standard) | todo | claude | T07 | App/Sources/UI/Viewport |
| T19 | Selezione ed evidenziazione nel viewport (picking) | todo | claude | T07 | App/Sources/UI/Viewport |
| T20 | Comandi, menu, scorciatoie, stati vuoti, onboarding | todo | claude | T17, T04 | App/Sources/UI/Commands<br>App/Sources/UI/Onboarding |
| T21 | Piatto di stampa a schermo (volume stampante, oggetto appoggiato) | todo | claude | T07, T12 | App/Sources/UI/Viewport |
| T22 | Pannello stampabilità: report visivo, evidenzia problemi | todo | claude | T11, T19 | App/Sources/UI/Printability |
| T23 | Dialog di esportazione STL/3MF (formato, risoluzione, anteprima) | todo | claude | T10, T17 | App/Sources/UI/Export |
