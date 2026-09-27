# Elettronica — prove del motore e dell’app

## T93 — schema elettrico, 27/09/2026

Motore proprietario implementato in `Schematic/`, contratto app in [SCHEMATIC.md](SCHEMATIC.md). Fogli con gerarchia organizzativa, simboli con identità condivisa col PCB, fili/giunzioni espliciti, etichette di rete/alimentazione, NC, anteprime e transazioni; connettività derivata e collegamenti diretti conservati separatamente. Componenti creati nello schema con un solo undo e senza posizione PCB inventata; posa PCB successiva esplicita. Formato 3 con lettura 1/2/3 e storico completo.

| Prova | Evidenza |
|---|---|
| `bash scripts/test-electronics.sh` | PASS: 71 test Swift (18 nuovi di schema), CLI import/assemblaggio/schema e tre lettori Python indipendenti. Artefatti `build/electronics/run.kRrlhj`. |
| Topologia | Ponte cancellato separa due reti; incrocio senza giunzione resta isolato; giunzione esplicita li collega; etichette tra fogli condividono netID; reti nominate diverse rifiutano cortocircuiti. |
| Comandi | Preview deterministica senza modifiche; simboli mossi/ruotati/specchiati aggiornano estremi fili, PCB invariato; NC e riferimenti mancanti rifiutati; batch fallito non lascia modifiche; rete rinominata non si fonde implicitamente. |
| Persistenza | Creazione, modifica, undo/redo, codifica comandi, riapertura; catene storico e proiezione netlist incoerenti rifiutate. |
| Selezione | Primitive semantiche, pin con identità componente+pin, BVH per pick/snap; priorità dei terminali, filtro e griglia solo senza geometria vicina. |
| Lettore indipendente | Python ricostruisce la connettività dai terminali senza usare la netlist Swift, verifica separazione delle isole, storico, identità PCB e coordinate dei pin dopo trasformazioni. |
| Import | `symbolNames` usa il parser ufficiale KiCad: definizioni top-level, Unicode e stringhe con parentesi, duplicati/malformati rifiutati. |
| CAD | 174 test CADCore PASS; nessuna modifica al CADCore da Codex. |

Prestazioni sintetiche, Mac locale, 1000 simboli/9000 primitive, 1000 query pick+snap: misura Release finale snapshot 38,09 ms, p95 query 0,0055 ms, massimo 0,0815 ms; artefatti `build/electronics/schematic-release-final`. In Debug la stessa costruzione completa richiede circa 1259 ms (p95 query 0,048 ms): **snapshot/preview devono essere eseguiti in background e conservati per revisione**, non ricalcolati a ogni hover. Le misure non certificano ogni macchina né progetti reali più complessi; il test CI registra i tempi senza soglia instabile. Rendering dell’app e GPU non misurati da questo benchmark.

Stato app: API consegnate a Claude; integrazione Schema/PCB in T97 in corso, nessuna prova a schermo del nuovo schema ancora attestata. Il precedente collaudo PCB qui sotto resta distinto. Non dichiarare completo E2: bus, porte e istanze gerarchiche riutilizzabili, multisezione e matrice ERC configurabile non sono implementati. L’ERC aggiunto segnala ingressi/alimentazioni senza driver, reti a pin singolo, simboli non posati e giunzioni sospese; non simula il circuito. Routing/DRC/Gerber restano E3/E4.

## T93 — primi strumenti di costruzione, 27/09/2026

Richiesta di Ross dopo la prova di Circuiti: da una scheda vuota mancavano inserimento componenti, connessioni e modifica scheda. Verificato da Codex sia nei sorgenti sia nella UI della build 1.0.0 compilata alle 10:32: barra con Nuovo/Apri/Salva/Esempio/Ruota/Lato/JLCPCB, senza strumenti di creazione.

Le API [EDITING.md](EDITING.md) sono implementate e compilano: documento vuoto, modelli generici nativi, catalogo comandi transazionali, anteprime complete di connettività, inserimento/modifica/rimozione componenti, spostamento/rotazione/lato, modifica scheda, reti e connessioni/NC. Diagnostica ERC con ID dei soggetti. Claude ha preso T97 per collegare gli strumenti visibili.

| Prova automatica | Esito |
|---|---|
| `bash scripts/test-electronics.sh` | PASS: 53 test Swift, compresi 13 nuovi `EditingTests`; entrambe le CLI e i due lettori Python indipendenti passano. Artefatti `build/electronics/run.QT3tI6/`. |
| `swift test --package-path Packages/CADCore` | PASS: 174 test sul checkout corrente. Nessuna modifica a CADCore da Codex. |
| Percorso costruito nei test | Vuoto → due componenti → rete e due pin con un undo → modifica scheda → salvataggio/riapertura → undo/redo con identità e connettività conservate. |
| Casi di rifiuto | Conflitti di libreria, sigle duplicate, ID/pin mancanti, revisione cambiata dopo preview, reti diverse, NC su pin collegato, angoli/quote invalidi e contorni autointersecanti: documento e storico intatti. |

Questi risultati provano il motore. I tre modelli generici non sono componenti qualificati presso un produttore. Connessioni logiche, nessun rame sbrogliato, Gerber o approvazione produttiva.

### Collaudo UI con Claude T97

Codex ha provato la build locale 1.0.3, compilata alle 10:47, nella finestra separata “Senza titolo”, preservando la precedente app di Ross con modifiche non salvate. Azioni eseguite tramite interfaccia nativa, non chiamate dirette al modello:

- Nuovo circuito → Componente → Resistenza 0603 → due clic sulla scheda → R1 e R2 presenti. Sono disponibili anche condensatore 0603 e connettore 1×02; questi ultimi non sono stati posati in questa prova.
- Scheda → 80 × 60 × 1,6 mm → conferma → Annulla/Ripeti → riapertura del pannello con 80 × 60. Larghezza zero disabilita OK e mostra l’errore; Annulla lascia intatta la scheda.
- Ruota R2 → 90°; Lato → sotto; Elimina → un componente; Annulla → due componenti. Ulteriori annullamenti ripristinano il lato sopra e 0°.
- Salva → Apri `.ftkc`: R1/R2 e storico ripristinati. Il lettore JSON Python conferma il contorno 80 × 60, due componenti, revision 11, tre passi annullabili e tre ripetibili in quel salvataggio intermedio.

Artefatto prodotto dalla UI: `build/electronics/run.QT3tI6/circuiti-verifica-ui.ftkc`. La cartella build è locale e ignorata da Git.

La revisione dell’integrazione ha individuato due difetti, segnalati e presi in carico da Claude: confronto del solo padID fra componenti che condividono la stessa impronta, e identità/revisione non mantenute fra anteprima e conferma. Correzioni nel commit Claude `4fea79a`, build 1.0.6 delle 10:58: prova con clic su R1.1 e R2.1 PASS, appare una rete e un collegamento da sbrogliare; Annulla rimuove entrambi e Ripeti li ripristina. File nuovamente salvato: revisione 14, quattro passi di storico, due componenti, una rete N1 e due connessioni. Lettore JSON Python conferma stesso pinID di libreria e componentID distinti. La CI di Claude `build/ci/run.JHJuEq` riporta 15/15 PASS, incluso test-circuits con regressioni per identità stabile, revisione obsoleta e collegamento fra pin uguali su istanze diverse; log app `BUILD SUCCEEDED`. Il mancato clic iniziale durante l’automazione dipendeva dalla finestra non attiva, risolto aprendola da Finder.

Restano assenti schema gerarchico editabile, routing del rame, DRC geometrico completo, Gerber e integrazione produttiva. Questi strumenti iniziali non completano l’intero T93/T97.

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

## Limiti della consegna E0 (storico)

Al momento di E0 il package non era collegato all’app e non erano stati importati campioni reali. E1 e il collaudo T93/T97 sopra aggiornano queste due condizioni. Nessuna validazione di asset 3D: sono presenti riferimenti e trasformazioni, non i modelli o un controllo collisioni. Nessun routing, piano di rame, DRC completo o Gerber. Nessun caricamento nel viewer JLCPCB e nessuna produzione fisica.

Il fixture è deliberatamente **sintetico**; identificativi, hash e calibrazioni non autorizzano un acquisto e non dimostrano la correttezza di componenti reali. Lo stato del pacchetto esportato è sempre `fabricationReady: false`.
