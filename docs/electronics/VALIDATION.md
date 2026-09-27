# Elettronica — prove del motore e dell’app

## T103 — preflight e fabbricazione a due strati, 27/09/2026

Contratto: [FABRICATION.md](FABRICATION.md). **155 test ElectronicsCore PASS**, inclusi
19 nuovi casi (15 iniziali + 4 limiti); **sette lettori Python indipendenti PASS**.
Comando `bash scripts/test-electronics.sh`, exit **0**, log
`/tmp/ftk-fabrication-final.log`, corpus `build/electronics/run.iPJHnT`.
`swift test --package-path Packages/CADCore --scratch-path build/codex-cad-fabrication-check`
exit **0**, **184 test CAD PASS** sullo snapshot della tappa 2 di Claude
(`587b69a`); modifiche CAD successive di Claude sono un'altra verifica.

La fixture di regressione contiene connettore PTH, resistenza top, diodo sintetico
bottom ruotato di 30°, quattro famiglie di piazzole, via, tre reti, origine spostata
(10,5 mm), coordinate negative nell'export e serigrafia. Non sono componenti qualificati.
Il pacchetto ha 17 file: nove Gerber, drill, job, BOM/CPL, elenco componenti,
preflight, README e manifest SHA-256. Nessun package runtime esterno.

- Rifiuti: corti, airwire, rame flottante, componenti non piazzati, ERC senza NC,
  componenti JLC senza codice o rotazione del lato; nessuna directory parziale.
- Mask/paste/silk: intervalli minimi, grafica sugli strati sbagliati, serigrafia sulle
  aperture o fuori bordo, pasta annullata, via coperti/aperti, PTH aperti da un solo
  lato e flip bottom, grafica piena con contorno, regioni degeneri in quantizzazione.
- Storico/revisione: preview ed export non mutano, versione7 invariata, revisione vecchia
  rifiutata dopo edit/undo, round-trip, varianti e DNP senza cambiare rame/fori/maschera.
- Lettore indipendente: **26.324 sonde** per ciascun export, forma dei flash confrontata
  col documento di input, piste/profilo/fori/origine e orientamenti, manifest e CSV.
  Secondo export con termiche: **407 regioni**, vuoto diagonale e quattro ponticelli
  realmente presenti nel Gerber; non basta contare le primitive.
- CLI: una directory già esistente resta byte per byte intatta; una scheda non
  sbrogliata non produce output. File di nomi fissi, senza nomi progetto usati come path.
- Release: build exit0; CLI completa (avvio processo, preflight, geometria, hash e I/O)
  **722,28 ms primo avvio**, poi **14,27 e 16,34 ms** sulla fixture piccola. Non è una
  misura di grandi schede o della reattività dell'app.

**Controllo esterno Ucamco:** nel Reference Gerber Viewer v2026-06, tramite Chrome,
caricati esclusivamente i nove Gerber e il drill della fixture sintetica. Tutti i nove
Gerber riconosciuti X2 e controllo sintattico **0 invalid / 0 deprecated** per ciascuno;
forature riconosciute NC drill. La visualizzazione completa non è qualificata: il
backend del sito ha restituito errore500 getstackup/No image server configured.
Il tentativo precedente nel browser integrato era fallito prima del caricamento.
Questo esito prova la sintassi ufficiale e il riconoscimento dei file; non prova
accettazione JLCPCB, correttezza dei componenti o produzione fisica.

**App/chat:** API congelate consegnate a Claude, che ha confermato il contratto e
la cooperazione. Aggancio Produzione e T100 ancora da collaudare; questo traguardo
riguarda motore, CLI e dati. Non dichiarare un nuovo pulsante disponibile nell'app.
Restano NPTH/asole/ritagli, multilayer, profili produttivi qualificati, dati reali e
collaudo della scheda scelta con Ross. T94/T95 avanzati restano aperti.


## 27/09/2026 — T94: termiche e minimo del piano

- **136 test Swift PASS**, 12 nuovi; **sei lettori Python indipendenti PASS**. Esecuzione
  completa exit0 `/tmp/ftk-thermals-final.log`, artefatti `build/electronics/run.BZv5Gj`.
- **180 test CADCore PASS**, exit0 `/tmp/ftk-thermals-cad.log`; nessun file CADCore modificato.
- Termiche SMD e passanti, fori/via, rotazione e lato inferiore, raggio interrotto solo
  parzialmente, isolamento anche della piazzola esterna al contorno, collo lungo rimosso e
  corto diagnosticato, collo ruotato, giunzioni delle celle preservate, cancellazione del
  filtro, rifiuto atomico, preview/UUID, storico/undo/redo e migrazione di tutta la catena v6.
- `check_thermals.py` verifica i poligoni esportati con aritmetica Python indipendente:
  copertura dell'intera larghezza dei raggi, vuoti termici, ostacoli, clearance POWER,
  isolamento e colli, area e interni non sovrapposti, catena persistente. Il corpus denso
  verifica separatamente la presenza dei 64 raggi; non prende il conteggio Swift come prova.
- Release finale: quattro piazzole filtrate **117,77 ms**, query pick+pickZones+snap
  **p95 0,0317 ms**; 16 piazzole, 525 celle, **308,75 ms** (`thermals-release-03`).
  Exit0 `/tmp/ftk-thermals-release-final.log`, lettori PCB/regole, piani e termiche PASS.
  Debug finale: quattro piazzole **1641,50 ms**; 16 piazzole **4191,00 ms**. Misure locali
  sintetiche: il worker cancellabile rimane necessario. Non è una misura su schede industriali.

API in [PCB_THERMALS.md](PCB_THERMALS.md). Core `15edf22`; UI di Claude `c28aaee`,
CI **16/16 PASS** `build/ci/run.FzJpQq`, `BUILD SUCCEEDED`, build **1.0.43** alle16:42.
Prova grafica nella copia Debug con `build/electronics/thermals-release-03/thermals-ui.ftkc`
(copia distinta di solid, quattro R/GND e pista POWER):

- Pieno1314,0 mm² → Termiche1308,7 mm², quattro piazzole con ponticelli visibili,
  zero collegamenti da sbrogliare.
- Piazzole isolate1304,0 mm², tre collegamenti da sbrogliare; distanza visibile nel pannello.
  Annulla ripristina le termiche, Ripeti reisola.
- **Difetto trovato nel collaudo reale:** minimo0 → digitazione0,2/Invio ritorna0. La fixture
  salvata revision11/past11 contiene due comandi0,2 poi0. Il binding leggeva il modello ancora
  vecchio mentre il worker applicava la modifica. Segnalato a Claude; richiesti bozza locale,
  conferma unica e protezione della sessione/piano. Il test del solo Model non lo riproduceva.
- Fixture salvata dopo prova isolamento/undo: revision15/past11/future1, termiche/minimo0.
  La correzione viene verificata nel ciclo seguente.

Correzioni UI: `ea87a61` introduce la copia locale; `1ea79fb` aggiunge anteprima,
Applica/Ripristina espliciti; `802c983` usa la base della modifica per distinguere una bozza
reale da un pannello pulito durante Annulla. Verifica a schermo:

- Build16:53, etichetta1.0.45/a9bd6bd+ con Applica/Ripristina: minimo0,2 → anteprima valida →
  Applica → salva **revision16/past12**, un solo comando. Minimo0,5 con ponticelli0,4:
  anteprima mostra zero raggi, conferma rifiutata, bozza mantenuta, Ripristina torna0,2.
- Difetto residuo trovato: Annulla correggeva il documento ma lasciava il campo0,2 con
  una falsa bozza. La correzione `802c983` viene collaudata nella build16:58, etichetta
  **1.0.46/1ea79fb+**, prima del commit: file riaperto con redo persistente, Ripeti0→0,2,
  Annulla0,2→0 senza pulsanti di modifica pendente. PASS.
- Ultima prova: nella stessa bozza minimo0,2 e gap0,5, anteprima valida, Applica una sola volta.
  File **revision20/past12**; Annulla ripristina entrambi0/0,4 e Ripeti0,2/0,5.
  Salva/Riapri conserva campi, quattro termiche e zero collegamenti da sbrogliare;
  area1306,7 mm², un'isola, area stretta rimossa0,2 mm² (valori arrotondati dalla UI).
- Fixture finale **formato7/revision22/past12/future0**, verificata anche leggendo JSON:
  coppie before/after coerenti, ultimo after uguale al disegno. Originale solid invariato.
  Nessuna modifica del CAD originale di Ross; solo la copia del circuito di collaudo.

CI finale di **802c983**, eseguita da Claude nel worktree isolato: **exit0 e16/16 PASS**,
`run.Kkf9PQ`. Risultato `ci 0` e riga finale dei16 passaggi letti direttamente nell'output
del suo comando; log completo conservato in `build/electronics/ci-802c983-final.log`
(il worktree temporaneo è stato rimosso da Claude). Core invariato da15edf22.

Il collaudo dei piani pieni riportato sotto resta evidenza storica distinta.
Nessuna qualificazione produttiva; `fabricationReady` resta `false`.

## 27/09/2026 — T94: piani di rame a collegamento pieno

- Suite elettronica: **124 test Swift PASS**, 17 nuovi sui piani; **cinque lettori Python
  indipendenti PASS**, incluso `Tests/Electronics/check_zones.py`. Esecuzione completa exit 0:
  `/tmp/ftk-zones-complete.log`, artefatti `build/electronics/run.55mFbj`.
- CADCore: **178 test PASS**, exit 0 `/tmp/ftk-zones-cad.log`. Nessuna modifica Codex al CAD.
- Nuovi casi: intersezioni concave e ostacoli sovrapposti, bordo e classe più severa,
  esclusione keepout per tipo/strato, isole separate e ponte di rame, collegamento tra strati
  solo attraverso via/pad passanti, fori vuoti, zone senza pad, UUID/pick/snap, atomicità,
  preview/storico, migrazione v5→v6 dell'intera catena, ordine deterministico, cancellazione,
  coordinate lontane e eventi quasi coincidenti, margine circolare circoscritto e limite di complessità.
- Il lettore Python misura distanze dai poligoni esportati, ne verifica copertura e interni
  disgiunti e ricostruisce la connettività con union-find proprio: le due piazzole sono collegate
  dal piano; il keepout le separa; una pista ripristina il collegamento. Controlla anche
  storico e riapertura. Non chiama il motore Swift per decidere il risultato.
- Release: `swift run -c release --package-path Packages/ElectronicsCore electronics-pcb
  build/electronics/zones-release-20260927`, exit 0; lettori PCB/regole e piani PASS.
  Log `/tmp/ftk-zones-release.log`. Piano con 100 ostacoli e 1.441 celle: snapshot **35,91 ms**,
  pick + pickZones + snap **p95 0,0234 ms**; Debug **401,49 ms / 0,1812 ms**.
  Misure sintetiche su questo Mac, non garanzie per progetti arbitrari. Worker cancellabili necessari.

Core `ccd15d7`; aggancio T97 di Claude `ae1a607`, build **1.0.33** compilata alle 14:44.
CI completa **16/16 PASS**, exit 0 e `BUILD SUCCEEDED`: `build/ci/run.XQ0IdU`.
Anche il test del ponte app `02g-circuiti-app` passa: piano con ID della preview, selezione,
modifica/spostamento/rimozione, undo, persistenza, comandi del rame fuori dal MainActor,
blocco dei doppi invii e cancellazione durante il lavoro senza installare il risultato.
Il worker verifica token, epoca documento e revisione; bozza conservata fino al successo.
Queste sono prove automatiche del Model dell'app, **non un collaudo visivo**.

Il tentativo di collaudo grafico del 27/09 alle 14:45–14:47 è bloccato dallo strumento CUA:
`cgWindowNotFound` per il percorso esatto della build, Finder e Claude; reset della sessione
e nuovo aggancio senza risultato. Nessuna evidenza di difetto di Circuiti da questo errore.
A quell'ora la build 1.0.33 non era stata verificata a schermo e la fixture UI era
rimasta invariata. Il controllo è tornato disponibile alle 15:46; risultati sotto.
Undo/redo non ricalcolano il rame nel core.

Limiti espliciti in [PCB_ZONES.md](PCB_ZONES.md): mancano termiche, larghezza minima dei colli,
priorità tra reti sovrapposte e qualificazione produttiva; il riempimento usa connessioni piene.

### Collaudo UI T97 del 27/09, dalle 15:46

Prova nella copia separata dell'app, senza modificare l'app originale di Ross. Fixture
`build/electronics/run.55mFbj/pcb/zones-ui.ftkc`: copia di `zones-before.ftkc`, inizialmente
revision6 e sei passi, due R collegate logicamente a GND e pista POWER con classe da 0,75 mm.
Operazioni eseguite tramite UI nativa, senza chiamare direttamente il Model.

Su **1.0.33 / ae1a607+**, compilata alle 14:44:

- Disegnato piano GND: anteprima ritagliata intorno a POWER e ai pad senza rete;
  conferma **1145,4 mm²**, un'isola e zero collegamenti da sbrogliare.
- Area vietata verticale: dopo conferma **1097,9 mm²**, due isole e un collegamento
  da sbrogliare. L'area vieta anche POWER; disattivando «Piste» il relativo errore sparisce,
  mentre il taglio del piano rimane perché «Piani» è ancora attivo.
- Pista GND da un'isola all'altra: aggancio al rame effettivo, ponte di 6,9 mm,
  un'isola connessa e zero collegamenti da sbrogliare. Annulla ripristina due isole/un
  collegamento; Ripeti ripristina il ponte, in un solo passo.
- Salva → Apri, verificando il nome della fixture selezionata: piano, aree e ponte
  conservati. Annulla/Ripeti dopo riapertura PASS. Python verifica formato6, revision14,
  dieci passi, `past[-1].after == design` e tutte le coppie before/after coerenti.

Difetti riprodotti e corretti da Claude in **692c492**: l'anteprima dell'area vietata
mostrava il vecchio piano pieno fino alla conferma; piano e area potevano restare selezionati
insieme. Il worker ora restituisce tutti i riempimenti candidati anche per aree e regole;
la conferma mantiene selezionato un solo oggetto.

Nuova prova su **1.0.36 / 692c492+**, compilata alle 15:54; CI `build/ci/run.yGjpJG`
**16/16 PASS**, log del ponte app PASS e `08-app.log` con `BUILD SUCCEEDED`:

- Riaperta la stessa fixture: zero collegamenti da sbrogliare.
- Nuova area rettangolare all'interno del piano: il foro nel rame è visibile **prima**
  della conferma; cambio ad altro strumento e ritorno conserva i due punti e l'anteprima.
- Clic ripetuto sull'ultimo punto chiude il rettangolo in un passo. Annulla ripristina
  il rame. Ripetuta la creazione con piano già selezionato: dopo Invio resta solo
  il pannello dell'area, senza selezione concorrente del piano.
- Una terza area abbozzata e annullata con Esc non cambia il rame né aggiunge storico.
  Salvataggio finale: **revision17, undici passi, zero redo, un piano, due aree e due piste**.
  Lettura JSON Python: catena completa coerente, ultimo stato uguale al design corrente.
  La fixture iniziale `zones-before.ftkc` è rimasta intatta.
- Piano POWER sovrapposto a GND: anteprima «Non confermabile», conferma rifiutata
  senza perdere la bozza. Esc e Salva lasciano revision17, undici passi e solo il piano GND.

Ricontrollo CADCore nello stesso turno: `swift test --package-path Packages/CADCore`,
exit 0, **178 test PASS**, log `/tmp/ftk-zones-ui-cad-20260927.log`.

L'apertura è stata spostata fuori dal MainActor da Claude in `6e206a4`. La revisione
Codex ha individuato una protezione incompleta: l'epoca da sola non impediva di perdere
modifiche fatte durante la lettura dello stesso documento. Claude ha corretto in `a630edb`
e `216a422`: identità/revisione, token dell'ultima richiesta, cancellazione e controllo
prima di propagare anche gli errori; una bozza nuova o modificata durante la lettura fa
cedere l'apertura. Test deterministici con lettura sospesa fino al rilascio esplicito:
modifica del documento, due richieste completate in ordine inverso, cancellazione,
bozza iniziata e vertice aggiunto a una bozza esistente. La prima correzione passa la
CI `build/ci/run.cqYCyJ` **16/16**; l'estensione finale passa la CI
`build/ci/run.CleO2V` **16/16**, incluso ponte Circuiti e `BUILD SUCCEEDED`.
Queste verifiche del Model sono distinte dal Salva/Apri sequenziale a schermo riuscito sopra.

Ultimo controllo UI: build **1.0.38 / 216a422+**, compilata alle **16:09**. Riaperta la
fixture revision17 attraverso il pannello nativo e mostrata in PCB: piano, due aree,
ponte e zero collegamenti da sbrogliare conservati; Annulla espone l'ultima operazione
«Crea area vietata». Nessuna ulteriore modifica al file in questa riapertura.

## 27/09/2026 — T94: classi di rete e aree vietate

- Suite elettronica: **107 test Swift PASS**, 19 nuovi sulle regole; quattro lettori
  Python indipendenti PASS. Processo `bash scripts/test-electronics.sh` exit 0,
  artefatti `build/electronics/run.7d8g5T/` (106 test al primo giro). Dopo il resolver
  batch, suite Swift completa 107 PASS, exit 0: `/tmp/ftk-pcb-rules-bulk.log`.
- Test: minimi globali non aggirabili, preferenze risolte, DRC su larghezza/fori/anello,
  clearance più severa fra reti anche nell'indice spaziale; assegnazioni esclusive,
  classe ereditata su split e merge di classi diverse rifiutato; keepout concavo,
  tangenza/larghezza, strati e tipi, pad ruotati e sul fondo, esclusione del foro vuoto;
  comandi atomici, ID, snapshot immutabile, pick/snap, formato4→5 e storico completo.
- La CLI `electronics-pcb` produce `rules.ftkc`, preview rifiutate, snapshot, valori
  risolti, undo/redo. Il lettore Python ricalcola larghezze, distanza di due tracce,
  distanza dal rettangolo e filtro degli strati senza chiamare il DRC Swift; verifica
  anche che i quattro tentativi rifiutati non siano nel documento e la catena storica.
- CADCore: **177 test PASS**, exit 0. Comprende il lavoro lamiera contemporaneo di
  Claude, letto e testato senza modificare i suoi sorgenti.
- Release: `build/electronics/pcb-rules-release-20260927-1309/`: 2.000 aree,
  snapshot 1,31 ms; query combinate pick+snap p95 0,0047 ms. Corpus sintetico di
  rettangoli distribuiti, non garanzia su ogni progetto. Snapshot/preview restano
  cancellabili in background; la risoluzione completa delle regole non va fatta a ogni hover.

Contratto e limiti in
[PCB_RULES.md](PCB_RULES.md): nessun piano di rame, Gerber, collaudo del produttore o
scheda fisica. Le prove PCB precedenti sotto restano riferite alle rispettive build.

### Collaudo UI T97 del 27/09, ore 13:27–13:36

Core nei commit `da1f641` e `873c78d`; UI di Claude in `b2b65d5`. Prova effettiva sulla
copia separata dell'app v1.0.21, indicazione `873c78d+`, compilata alle 13:26 con gli
ultimi sorgenti UI prima del commit. CI integrata finale `build/ci/run.7hhAmx`: 16/16
PASS, `08-app.log` con BUILD SUCCEEDED; la build 1.0.23 successiva non era quella aperta
durante questa prova.

- Classe «Potenza», assegnazione di SIGNAL prima della modifica: Applica conserva la
  rete. Minimo 0,5 mm segnala le due piste esistenti da 0,25 mm; il rame resta invariato.
- Minimo −1, Chiudi → Applica: rifiuto con pannello e draft conservati. Correzione a
  0,2 mm accettata; preferenze pista 0,5 mm, via 0,8 mm e foro 0,4 mm usate dal router.
- Area rettangolare sul rame sopra: anteprima stabile e un conflitto già prima di
  confermare; conferma, Annulla e Ripeti producono rispettivamente uno, zero e un errore.
- Nuova pista nell'area: anteprima rossa e conferma rifiutata. Esc non lascia rame.
  Trascinamento dell'area fuori dalla pista: errore eliminato; un singolo Annulla lo
  ripristina, Ripeti lo elimina.
- Salvataggio e riapertura: classe, assegnazione, dimensioni, area e storico presenti.
  Annulla/Ripeti dopo riapertura cambia ancora il DRC correttamente.

Artefatto UI: `build/electronics/run.7d8g5T/pcb/rules-ui.ftkc`. Verifica indipendente
Python: formato5, revisione19 dopo l'ultima coppia undo/redo, 13 passi con catena
before/after coerente, due piste e un via originali, classe assegnata a SIGNAL e una
sola area spostata a y=15…18,25 mm; minimo negativo e pista rifiutata assenti da ogni
stato persistito. Decode del file tramite la libreria Swift compilata PASS.

Difetto confermato e corretto da Claude in `64f2973`: il precedente messaggio di errore
rimaneva dopo una modifica riuscita. Prova mirata sulla **v1.0.26 / 64f2973**, compilata
alle 13:38: pista nell'area rifiutata, Esc, trascina l'area fuori dal rame; lo stato diventa
«Sposta area vietata» e il DRC torna a zero errori. CI `build/ci/run.6kTf89`:
**16/16 PASS**, inclusi nuovi test del messaggio e del file mancante, BUILD SUCCEEDED.

**Rettifica della prima diagnosi sul pannello Apri:** un clic automatizzato CUA richiesto
sul nome del circuito selezionava invece `rule-preview-keepout.json`; l'errore «missing»
non dimostrava un difetto di riapertura del circuito. La selezione è stata isolata e
controllata prima di Open. Salva → Apri immediato, prima riga scelta con la tastiera:
**PASS**, «Aperto rules-ui-io» e dati integri. Anche un URL esposto da AX come
`com-apple-unresolvable-file-reference-url:` non ha impedito questa apertura e da solo
non prova un errore I/O. La conversione al percorso e il messaggio italiano per file
mancante aggiunti da Claude restano un irrobustimento; non una corruzione riprodotta.
La prova finale usa una copia `rules-ui-io.ftkc`, lasciando intatta `rules-ui.ftkc`.

## 27/09/2026 — T94: motore del rame e DRC iniziale

- `bash scripts/test-electronics.sh`: **88 test Swift PASS**, 17 nuovi test PCB;
  quattro lettori Python indipendenti PASS (assemblaggio, librerie, schema, PCB).
  Artefatti `build/electronics/run.fUyGr4/`, esito processo 0.
- PCB: traccia continua/rotta, strati sovrapposti isolati, via e pad passanti, foro vuoto,
  corti e distanze reali, anelli/fori/larghezze/bordo concavo, NC, rete trattenuta dal rame
  dopo eliminazione del filo, preview non mutante e non confermabile, batch atomico,
  revisione obsoleta, migrazione 1–3, salvataggio/undo/redo, cancellazione, pick/snap.
- Il lettore `Tests/Electronics/check_pcb.py` ricalcola dai dati i pad ruotati/specchiati,
  la continuità su due strati attraverso il via, i diametri, il corto perpendicolare e la catena
  dello storico. Non richiama le funzioni Swift sotto prova. È una fixture indipendente,
  non un corpus produttivo universale.
- `swift test --package-path Packages/CADCore`: **174 PASS**, esito processo 0.
- Benchmark Release `build/electronics/pcb-release-20260927-1240/metrics.json`: 1.000
  capsule distribuite, snapshot 5,30 ms; 1.000 query pick+snap, p95 0,0091 ms, max 0,088 ms.
  Debug finale: snapshot 35,19 ms, p95 0,0404 ms. Snapshot grandi e preview restano
  da eseguire in background con cache per revisione: non è una garanzia su qualsiasi PCB.
- Documento formato **4**. Vecchie versioni devono rifiutarlo; il nuovo lettore conserva
  contenuto e storico di 1–3. La semplice assenza di DRC non significa fabbricabilità.

Copertura e limiti: [PCB.md](PCB.md). Non inclusi piani, shove, archi, net class, keepout,
regole mask/copper-to-hole complete e Gerber. `fabricationReady` resta false.
### Collaudo UI T97 del 27/09, ore 12:53–12:55

App reale `build/DerivedData/Build/Products/Debug/FusionTakeoff.app`, v1.0.15,
commit indicato `9744636+`, compilata alle 12:52 con i sorgenti T97 poi committati
in `9e8e987`. CI integrata `build/ci/run.2tevuw`: 16/16 PASS e BUILD SUCCEEDED.

Copia della fixture senza via: apertura in PCB con due piste su strati distinti e una airwire.
Pista → punto centrale → V → Invio: compare via, airwire 1→0. Annulla: 0→1;
Ripeti: 1→0. Pista dal pad R1, clic nel vuoto, V, clic sul pad inferiore R2:
percorso di 28,9 mm con un altro via, due tratti su strati distinti, un solo passo di storico.
Tentativo dal pad collegato al pad senza rete di R1: conferma rifiutata con messaggio italiano,
nessuna modifica persistente. Esc, Salva, Apri: rame ripristinato e zero airwire.

File prodotto dalla UI: `build/electronics/run.fUyGr4/pcb/pcb-ui.ftkc`.
Lettura Python: formato4, revisione10, quattro piste, due via, otto passi before/after
coerenti, redo vuoto; l’ultimo passo aggiunge i due tratti e il via insieme. Il corto
rifiutato non è nel file. Nessuna fabbricazione o scheda fisica verificata.

Il collaudo schema delle sezioni seguenti è storico.


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

Passaggio a **macOS 27 minimo**, richiesto da Ross: package verificato con macOS 27.0 (26A428), Xcode 27.0 (27A266a) e SDK 27.0. `bash scripts/test-electronics.sh` passa ancora 71 test e tre lettori indipendenti; artefatti `build/electronics/run.Ug7ixv`. Il requisito di sistema non dimostra da solo l'adozione di nuove API.

### Collaudo UI dello schema con Claude T97

Codex ha provato la build 1.0.10/9f76573+ delle 11:36, con l'aggancio UI non ancora committato di Claude, nella finestra separata di collaudo. Azioni reali nell'app: Nuovo → posa R1/R2 nello schema → Filo R1.2–R2.1 → NC R1.1 → Ruota R2 (il filo segue il pin) → etichetta SIGNAL → PCB con due componenti da posare → posa entrambi, una airwire → Annulla/Ripeti → Salva/Apri. Tutte passate; il nuovo schema riaperto mostra simboli, filo, NC ed etichetta.

File prodotto dalla UI: `build/electronics/run.Ug7ixv/schema-collaudo-ui.ftkc`. Python conferma formato 3, revisione 11, nove passi dello storico con catena before/after coerente, due identità condivise fra schema e PCB, due posizionamenti PCB, un filo, rete SIGNAL e un NC. Non si è modificata l'app originale di Ross.

La prima CI su target macOS 27, `build/ci/run.wMGVog`, conferma 174 test CAD, test del ponte Circuiti e `08-app.log` con `BUILD SUCCEEDED`. Il binario app e la CLI elettronica dichiarano `minos 27.0` e `sdk 27.0`, verificati con `xcrun vtool -show-build`.

Difetti individuati e consegnati a Claude: ricostruzione sincrona di snapshot/anteprima sul main thread, camera riadattata a ogni posa/rotazione anziché solo con Adatta, guida Schema che mostra ancora «F cambia lato» del PCB. Nuova prova su build delle 11:50, target macOS27: posa R1 al clic e successiva posa/rotazione R2 mantengono ferma la camera; guida M corretta. Background e cache verificati nei sorgenti; la cancellazione del worker è stata poi corretta con withTaskCancellationHandler, senza misurazione dello scheduling a schermo. La prova funzionale non certifica prestazioni su schede reali grandi.

Consolidamento: motore in `9f76573`, app e correzioni di Claude in `4e1b280`. CI integrata finale `build/ci/run.gkEkgl`: Claude conferma 16/16 PASS; Codex ha letto direttamente il log del ponte Circuiti (schema/PCB, fili, etichette, NC, giunzioni, undo, salva/riapri) e il `BUILD SUCCEEDED` dell'app. Nessun nuovo test fisico o rilascio produttivo implicito.

Non dichiarare completo E2: bus, porte e istanze gerarchiche riutilizzabili, multisezione e matrice ERC configurabile non sono implementati. L’ERC aggiunto segnala ingressi/alimentazioni senza driver, reti a pin singolo, simboli non posati e giunzioni sospese; non simula il circuito. Routing/DRC/Gerber restano E3/E4.

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
