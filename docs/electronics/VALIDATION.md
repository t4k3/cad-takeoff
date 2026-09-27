# Elettronica — prove E0/E1

## T93 — primi strumenti di costruzione, 27/09/2026

Richiesta di Ross dopo la prova di Circuiti: da una scheda vuota mancavano inserimento componenti, connessioni e modifica scheda. Verificato da Codex sia nei sorgenti sia nella UI della build 1.0.0 compilata alle 10:32: barra con Nuovo/Apri/Salva/Esempio/Ruota/Lato/JLCPCB, senza strumenti di creazione.

Le API [EDITING.md](EDITING.md) sono implementate e compilano: documento vuoto, modelli generici nativi, catalogo comandi transazionali, anteprime complete di connettività, inserimento/modifica/rimozione componenti, spostamento/rotazione/lato, modifica scheda, reti e connessioni/NC. Diagnostica ERC con ID dei soggetti. Claude ha preso T97 per collegare gli strumenti visibili.

| Prova automatica | Esito |
|---|---|
| `bash scripts/test-electronics.sh` | PASS: 53 test Swift, compresi 13 nuovi `EditingTests`; entrambe le CLI e i due lettori Python indipendenti passano. Artefatti `build/electronics/run.QT3tI6/`. |
| `swift test --package-path Packages/CADCore` | PASS: 174 test sul checkout corrente. Nessuna modifica a CADCore da Codex. |
| Percorso costruito nei test | Vuoto → due componenti → rete e due pin con un undo → modifica scheda → salvataggio/riapertura → undo/redo con identità e connettività conservate. |
| Casi di rifiuto | Conflitti di libreria, sigle duplicate, ID/pin mancanti, revisione cambiata dopo preview, reti diverse, NC su pin collegato, angoli/quote invalidi e contorni autointersecanti: documento e storico intatti. |

Questi risultati provano il motore. Il collaudo della nuova UI va registrato separatamente dopo la build T97: la UI precedente è stata osservata, la nuova non è attestata da questi test. I tre modelli generici non sono componenti qualificati presso un produttore. Connessioni logiche, nessun rame sbrogliato, Gerber o approvazione produttiva.

## E1 — librerie, 27/09/2026

T92, Codex. Esecuzione locale su macOS/arm64; nessuna prova UI elettronica o produzione fisica.

| Prova | Risultato verificato |
|---|---|
| `bash scripts/test-electronics.sh` | PASS: 40 test XCTest, zero errori; entrambi i programmi CLI compilati/eseguiti. |
| `Tests/Electronics/check_library.py` | PASS: hash del corpus con lettore SHA-256 Python; quote/raggio R0603, pin del simbolo R e foro/interasse header KiCad 9.0.0; scala/origine EasyEDA sintetico; quoting/catalogo; v1→v2 e catena storico; reimport idempotente; revisione obsoleta, file esistente e pad non supportato senza output parziale. |
| `Tests/Electronics/check_assembly.py` | PASS: tutte le verifiche indipendenti E0 su BOM/CPL, varianti, centri, angoli, matrici 3D e connettività. |
| `swift test --package-path Packages/CADCore` | PASS: 174 test. CADCore non modificato da T92. |

Artefatti: `build/electronics/run.BeZNsL/assembly/` e `build/electronics/run.BeZNsL/library/`. Lo script genera ogni volta una cartella nuova; build ignorata da Git. I campioni di componenti KiCad sono reali e fissati al tag 9.0.0, con attribuzione/licenza; EasyEDA, catalogo e circuito assemblato sono sintetici.

I test Swift aggiuntivi coprono sorgenti incompleti, limite profondità parser, Unicode/escaping, policy non rappresentabili, ereditarietà e rifiuto multi-unità, identità tra revisioni, pin-map proposta e confermata, rollback atomico, revisioni immutabili, hash incoerenti, strati invalidi, cache catalogo non valida e MPN non corrispondente.

Limiti verificabili: non sono stati provati componente reale JLC/LCSC, API fornitore autenticata, prezzi, modelli 3D reali, viewer JLC, schema/PCB a schermo, routing, Gerber o prestazioni interattive. E1 non chiude T92: catalogo live e corpus/feature aggiuntivi restano indicati in [ROADMAP.md](ROADMAP.md). `fabricationReady` rimane `false`. Le promesse al motore UX sono limitate a quelle descritte in [LIBRARIES.md](LIBRARIES.md).

## E0 — evidenza storica della prima consegna

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
