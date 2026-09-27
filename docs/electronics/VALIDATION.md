# E0 — prove della prima consegna

27/09/2026 · T91 · esecuzione locale macOS, Swift 6.4 · Codex.

| Prova eseguita | Risultato |
|---|---|
| `bash scripts/test-electronics.sh` | PASS: 19 test XCTest, zero errori. |
| Lettore indipendente Python sui CSV/JSON generati dal programma Swift | PASS: coerenza riferimenti BOM/CPL, escaping CSV, varianti e DNP/manuali, centri/origine, angoli top/bottom, matrici 3D ortonormali con determinante +1, connettività. |
| Tentativo di esportare su una cartella già esistente | PASS: exit 1 con `output_exists`; nessuna sovrascrittura. |
| `swift test --package-path Packages/CADCore` | PASS: 174 test sul checkout condiviso al momento dell’esecuzione. Nessuna modifica al CADCore da parte di T91. |
| `python3 scripts/graph.py validate` | PASS: grafo senza cicli. |

Artefatti generati dall’ultima esecuzione: `build/electronics/run.5S7GAe/assembly/` (`BOM.csv`, `CPL.csv`, `assembly.json`). La cartella build è ignorata da Git: il fixture e lo script versionabili permettono di rigenerarla. I numeri dei test CAD possono crescere mentre Claude sviluppa sul medesimo checkout.

## Copertura significativa

- Identità duplicate, riferimenti a pin/reti/componenti/revisioni assenti, mappature incomplete o ambigue.
- Assenza di crash con documenti incoerenti; quote non finite, contorni autointersecanti, fori senza anello anulare, path 3D non relativi.
- Stessa impronta con pin-map differente e più piazzole per uno stesso pin; lato inferiore e fori passanti.
- Export deterministico anche permutando l’ordine delle entità; BOM separata per dispositivo, valori con virgole e virgolette.
- Variante identica per BOM, CPL e assemblaggio meccanico; rame mantenuto anche per componenti esclusi dal montaggio.
- Mancanza di posizione, codice fornitore o regola angolare richiesta: errore esplicito, nessuna riga omessa silenziosamente.
- Trasformazione meccanica top/bottom controllata separatamente dai centri di presa del CPL.
- Transazione fallita senza stato parziale; storico e redo dopo riapertura; edit dopo undo; rifiuto della revisione obsoleta.
- Revisione di libreria immutabile nello storico; rifiuto di formato futuro e di catena undo alterata.

## Prove che non sono state eseguite e funzioni ancora assenti

Nessuna prova UI elettronica: il package non è ancora collegato all’app. Nessun componente reale scaricato/importato da JLCPCB, KiCad o EasyEDA. Nessuna validazione di asset 3D: sono presenti riferimenti e trasformazioni, non i modelli o un controllo collisioni. Nessun routing, piano di rame, DRC completo o Gerber. Nessun caricamento nel viewer JLCPCB e nessuna produzione fisica.

Il fixture è deliberatamente **sintetico**; identificativi, hash e calibrazioni non autorizzano un acquisto e non dimostrano la correttezza di componenti reali. Lo stato del pacchetto esportato è sempre `fabricationReady: false`.
