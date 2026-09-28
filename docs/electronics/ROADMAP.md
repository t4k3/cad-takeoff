# Elettronica — roadmap verificabile

27/09/2026 · Obiettivo: schede professionali, motore proprio, componenti reperibili e collegamento all’assieme CAD. Ogni voce distingue sviluppo del nucleo, integrazione UI e accettazione reale. Il grafo operativo è `docs/graph/GRAPH.md`, aggiornato solo da `scripts/graph.py`.

| Fase / task | Risultato | Criterio di uscita |
|---|---|---|
| E0 / T91 | Librerie revisionate, netlist, posizionamenti, storico, BOM/CPL e trasformazioni 3D | Test negativi e persistenza; lettore indipendente BOM/CPL; convenzioni top/bottom verificate con fixture. Core consegnato; UI e file produttivi esclusi. |
| E1 / T92 | Librerie native e import componenti; catalogo JLCPCB/LCSC | Importatori nostri KiCad ed EasyEDA con sottoinsiemi dichiarati; pin-map/datasheet verificati; provenienza e licenza conservate; cache offline; stock/prezzo con data; alternative proposte senza sostituzione automatica. |
| E2 / T93 | Schemi usabili e comandi comuni a UI/chat | Grafica simboli, fili/giunzioni, etichette, gerarchie, bus, componenti multisezione, NC; netlist indipendente dal disegno; matrice ERC, alimentazioni e diagnostica; modifica/ripristino/riapertura coerenti; prime API assistente. |
| E3 / T94 | PCB realmente sbrogliabile | Stackup e classi di rete; piste, archi, via, padstack SMD/THT, fori e contorni, keepout; DRC indipendente; routing manuale 45°/arco e ostacoli, poi push/shove; piani di rame e termiche; differenziali e lunghezze solo con prove dedicate. |
| E4 / T95 | Pacchetto fabbricazione e assemblaggio | Gerber X2/job, forature PTH/NPTH, maschera/pasta/serigrafia, BOM/CPL e disegni assemblaggio; confronto con parser/viewer indipendenti; profilo JLC revisionato; controllo reale orientamento/pin 1 e corrispondenza col datasheet. |
| E5 / T96 | Assieme elettromeccanico associativo | Contorno/spessore/fori scheda revisionati; componenti con modelli controllati; unità e orientamenti verificati; distanza da involucro, distanziali, connettori e volumi di rispetto; refresh esplicito, persistenza dei riferimenti. |
| UX / T97 | Workspace elettronica di Claude | Flussi Libreria→Schema→PCB→Assieme→Produzione, selezione incrociata, comandi annullabili, errori navigabili, tabella BOM, anteprima montaggio sopra/sotto. Ruolo confermato da Claude; vincolante UX_RULES.md. |
| E6 / T98 | Scheda campione accettata end-to-end | Stessa operazione da UI/chat/MCP; schema→PCB→modifica→ERC/DRC→riapertura→export→assemblaggio 3D; revisione incrociata degli export; prova sul produttore e sulla scheda reale documentate separatamente. |
| App / T99 | Claude collega ElectronicsCore all’app | Package nel progetto Xcode, Model/Electronics, documento nel progetto/Home e test dedicati nella CI globale. |
| Assistente / T100 | Claude collega UI/chat/MCP ai comandi E2 | Nessuna logica elettronica duplicata; stesse revisioni, anteprime, conferme e undo. |
| CAD / T101 | Claude realizza l’adattatore meccanico sopra E5 | Geometria e istanze nel CAD con riferimenti revisionati e trasformazioni fornite dal core. |

## Stato E1 al 27/09

T111 (28/09) introduce la [scheda assemblata da file di produzione](ASSEMBLY_VIEW.md):
catalogo proprietario di 15 package generici, substrato forato, corpi/pin 1 e selezione
nel sistema del documento, allineamenti e spessore nello storico formato9. Primo
controllo Ballgun:73 modelli approssimati su84 montati,11 montati ancora senza modello.
App2D/3D in integrazione con Claude/T97; esiti effettivi in [VALIDATION.md](VALIDATION.md).
Non chiude T96: mancano modelli specifici verificati, collegamento associativo al CAD
e controllo delle interferenze con l'involucro.

T108 (28/09) aggiunge l'[importazione di pacchetti Gerber/BOM/CPL](MANUFACTURING_IMPORT.md),
con geometria CAM conservata, riferimenti e lotti distinti, omissioni intenzionali,
preview/undo e storico formato8. Collaudato sul pacchetto reale Ballgun, incluse
100modifiche di lotto e riapertura. App/UX e comandi assistente affidati a Claude/T97;
stato delle prove completo in [VALIDATION.md](VALIDATION.md). Non equivale all'import
del progetto schematico o a un PCB nativo modificabile.

Prima consegna implementata e verificata: importazione KiCad di simboli mono-unità e impronte SMD/PTH, sottoinsieme SMD EasyEDA Standard, grafica e provenienza, proposte di pin-map, catalogo CSV offline, comandi di import/creazione dispositivo con anteprima e undo, documento v2 con lettura v1. [Copertura dettagliata](LIBRARIES.md), [prove](VALIDATION.md).

T106 implementa il [confronto delle revisioni](LIBRARY_REVISIONS.md): definizioni ed entità prima/dopo, campi cambiati, componenti agganciati alla revisione precisa. Preview non distruttiva e conferma con un solo passo di storico; nessun aggiornamento automatico dei componenti esistenti. Claude/T97 ha integrato l'anteprima nell'app: T107 verifica confronto, annullamento, conferma e storico dopo riapertura, oltre al reimport identico. Primitive geometriche condivise col DRC; [prove e limiti](VALIDATION.md).

T92 resta aperto: mancano adattatore catalogo JLC live documentato/autenticato, prezzi e politiche di aggiornamento, corpus EasyEDA e JLC reale con controllo dei datasheet, migrazione esplicita dei componenti fra revisioni e ampliamento dei formati. Le librerie multi-unità dipendono dal modello E2; padstack avanzati/NPTH dal modello E3. Nessuna promessa di import universale e nessun endpoint privato dedotto.

## Priorità Circuiti dopo la prova nell’app

Il collegamento T99 da solo ha esposto una scheda nuova priva di strumenti per popolarla. T93 implementa ora il contratto [EDITING.md](EDITING.md): inserire componenti da libreria o modelli generici, connettere pin, modificare scheda e componenti, preview/revisioni e undo. T97 di Claude aggancia Componente/Collega/Scheda/Elimina. Criterio di accettazione congiunto: costruzione da vuoto nell’app, modifica, annullamento, salvataggio e riapertura. Il secondo traguardo T93 implementa [SCHEMATIC.md](SCHEMATIC.md): schema con fogli, simboli, fili, giunzioni, etichette, rete derivata, snapshot/pick/snap, ERC iniziale e documento v3. 71 test del motore e lettore indipendente passano; Claude integra Schema/PCB nell’app. T93 completo (bus, multisezione, porte/istanze gerarchiche, matrice ERC configurabile) e T94 (piste/DRC) restano aperti; i collegamenti logici visualizzati non sono piste.

## Primo obiettivo utilizzabile

Una scheda a due strati, con connettori, componenti passivi, almeno un dispositivo polarizzato e montaggio su entrambi i lati. Deve passare dallo schema ai file produttivi e adattarsi a un contenitore CAD. Il circuito reale sarà scelto con Ross; il fixture E0 è sintetico e non rappresenta uno schema elettronico progettato.

Gli schemi più complessi, multistrato, QFN con pad termico, piani divisi, routing differenziale, pannellizzazione e flex richiedono corpus e criteri separati. La sola presenza del relativo comando non basta a dichiarare il supporto.

## Ordine delle priorità tecniche

1. Identità e connettività affidabili, revisione librerie e pin-map: un simbolo bello con il pinout sbagliato produce una scheda sbagliata.
2. Transazioni, diagnosi e storico equivalenti da UI e assistente. Ogni modifica dell’assistente parte da una revisione letta e produce un diff verificabile.
3. Rame e DRC robusti prima di router avanzati. Predicati/tolleranze e precisione da fissare su casi limite, non nascondere gli errori con arrotondamenti.
4. Fabbricazione e dati di montaggio controllati sullo stesso documento, con prova indipendente degli output e disponibilità aggiornata dei componenti.
5. Associatività con la meccanica e verifica di ingombri reali. Una trasformazione numerica corretta non certifica il modello scaricato o il volume necessario per inserire un connettore.

## Distinzione delle prove

- **Core**: test automatici, casi invalidi, regressioni, parser indipendenti.
- **App**: selezione, modifiche, annullamento, salvataggio e riapertura, prestazioni e accessibilità.
- **Fornitore**: interpretazione del pacchetto nel viewer, componenti esatti, orientamento/polarità e possibilità di assemblaggio.
- **Fisica**: scheda prodotta, continuità, alimentazioni e funzionamento, montaggio nel contenitore.

Non etichettare come «pronto produzione» un risultato verificato solo al primo livello. Nessun acquisto o ordine automatico fa parte dei task di sviluppo.

## Primo traguardo T94 — 27/09/2026

Implementati piste polilineari con larghezza, via passanti, 2–32 strati pari, regole del progetto,
DRC di rame/bordo/fori/anello, connettività fisica e airwire residue, snapshot indicizzato,
comandi e preview che rifiutano nuovo rame non conforme, documento v4 con undo persistente.
Contratto [PCB.md](PCB.md), prova automatica [VALIDATION.md](VALIDATION.md).
T102 registra la base schema già collaudata e sblocca T94/T100; T93 avanzato resta aperto.
T97 integra strumenti e disegno PCB nell’app; la prova a schermo resta distinta dal motore.
T94 resta aperto per archi, keepout, net class, stackup dielettrico, pour/termiche,
shove e controlli produttivi completi. Nessun Gerber o rilascio di fabbricazione implicito.


## Secondo traguardo T94 — classi e aree vietate, 27/09/2026

Motore implementato: classi esplicite con minimi e preferenze di routing separati,
risoluzione sopra i minimi della scheda, distanza più severa fra due reti; aree vietate
per strato/tipo con contorno concavo, primitive e pick/snap indicizzati. Regole modificabili
senza alterare il rame esistente, nuovi tratti non conformi rifiutati. Documento v5 con
lettura 1–5 e storico; classi conservate dopo separazione delle reti automatiche.
107 test motore, quattro lettori indipendenti e 177 CAD PASS. Contratto [PCB_RULES.md](PCB_RULES.md).
Claude ha integrato T97: Classi e Area vietata nella scheda PCB. Collaudo a schermo di
assegnazione, modifica, anteprima, rifiuto del rame vietato, spostamento, annulla/ripeti
e persistenza registrato separatamente in [VALIDATION.md](VALIDATION.md). Il difetto
del messaggio di stato è corretto e verificato nella v1.0.26; la prima diagnosi sul
pannello file è stata rettificata dopo aver isolato una selezione errata nell'automazione.
Restano T94 avanzato (archi, stackup dielettrico, pour/termiche, shove, DRC completo)
e T95 per fabbricazione. Nessuna qualificazione produttiva.

## Terzo traguardo T94 — piani di rame, 27/09/2026

Riempimento poligonale nativo Swift: contorno anche concavo, collegamenti pieni alle piazzole,
distanze da bordo e altre reti secondo le classi, fori e aree vietate. Connettività effettiva
tra celle, piste e via; isole senza percorso verso una piazzola rimuovibili, mai collegate
per il solo UUID del piano. Documento v6 con lettura 1–6 e storico completo. Contratto
[PCB_ZONES.md](PCB_ZONES.md), **124 test elettronici + cinque lettori + 178 CAD PASS**.
Claude ha integrato T97 in `ae1a607`, poi corretto anteprima e selezione in `692c492`:
app **1.0.36**, CI **16/16 PASS**, compresi i test del ponte app su preview, comandi
in background e cancellazione. Collaudo visivo eseguito su 1.0.33 e 1.0.36: piano,
taglio del rame, ponte fra isole, undo/redo anche dopo riapertura, bozza conservata
al cambio strumento e annullamento. Misure e limiti in [VALIDATION.md](VALIDATION.md).
Correzioni aggiuntive dell'apertura concorrente `a630edb`/`216a422`: modifiche e bozze
recenti preservate, ultima richiesta prevalente; test deterministici e CI finale 16/16.
Riapertura del circuito verificata anche nella build **1.0.38**.
Restano termiche, larghezza minima dei colli, archi, stackup dielettrico, shove e DRC completo;
T95 comprende il successivo rilascio produttivo. Nessuna libreria geometrica esterna aggiunta.

## Quarto traguardo T94 — termiche e larghezza del rame, 27/09/2026

Contratto [PCB_THERMALS.md](PCB_THERMALS.md): quattro ponticelli orientati su SMD/passanti,
modalità piena/termica/solo passanti/isolata, gap e larghezza configurabili, controllo dei raggi
realmente completi nel rame finale. Via pieni e fori vuoti. Filtro opzionale della larghezza
tramite erosione/dilatazione, senza cancellare le giunzioni artificiali delle celle; i colli
corti rimasti vengono diagnosticati. Implementazione nativa, senza dipendenze esterne.

Formato7 con migrazione completa1–7 e conservazione dello storico. 136 test Swift e sei
lettori Python indipendenti passano; corpus sintetico a 16 piazzole/64 ponticelli.
Aggancio UI e collaudo reale registrati in [VALIDATION.md](VALIDATION.md).

Restano priorità avanzate, override per pad, archi, stackup dielettrico, shove e DRC completo.
T94 resta aperto; questo traguardo non abilita un rilascio produttivo Gerber/JLCPCB.

## Primo nucleo E4 / T103 — fabbricazione due strati, 27/09/2026

[Contratto FABRICATION](FABRICATION.md): preflight completo rispetto al sottoinsieme
attuale, anteprima per strato e foratura, export atomico in memoria, CLI senza
sovrascritture. Gerber X2, PTH XNC/Excellon decimale, job, maschera/pasta/serigrafia,
BOM/CPL e componenti della stessa revisione; manifest SHA-256. Formato7 invariato.
155 test elettronici, sette lettori indipendenti e sintassi dei nove Gerber verificata
nel parser ufficiale Ucamco; limiti ed evidenze in [VALIDATION.md](VALIDATION.md).

T103 e il nucleo verificato per il primo pacchetto. T95 resta aperto: NPTH, asole,
ritagli, profili JLC qualificati e corpus reale non sono completati. La fixture resta
sintetica; produzione e montaggio fisico non provati. Claude ha ricevuto le API per
Produzione e T100; l'integrazione successiva è descritta qui sotto.

## App Produzione e assistente v1 / T100–T104 — 27/09/2026

Produzione nell'app: profilo e variante, nove anteprime, problemi navigabili,
cartelle nuove senza sovrascritture e nessuna modifica dello storico. Quattro export
dalla UI controllati indipendentemente, inclusi profilo modificato e variante DNP.

Il router espone 27 strumenti CAD e nove Circuiti con token separati. Il contratto
[ASSISTANT.md](ASSISTANT.md) copre componenti, connessioni/NC, scheda, piste e via,
anteprima/conferma, storico e preflight. Il protocollo locale è collaudato sull'app
reale; la prova in linguaggio naturale del singolo provider è registrata separatamente
in [VALIDATION.md](VALIDATION.md). [Procedura di accettazione](APP_ACCEPTANCE.md).

T98 resta aperto: parità con tutti i comandi dello schema e del PCB, componenti reali,
accettazione presso il produttore e assieme elettromeccanico non sono sostituiti da
questa integrazione iniziale.
