# Piano per un CAD professionale — ottobre 2026

26 settembre 2026 · richiesta di Ross: «siamo lontani da quello che voglio, fra un mese penso ci arriviamo».
Versione di partenza: 0.1.98 (98 commit, 97 test del motore, CI a 11 passaggi, TestFlight attivo).

## 1. Che cosa intendiamo per «professionale»

Un CAD con cui Ross e i colleghi progettano **pezzi meccanici reali** (RobotVolley, attrezzature,
lamiera, parti stampate) **dall'idea al fornitore**, senza tornare a Fusion:

1. schizzi **quotati e vincolati**: cambio una quota e tutto il pezzo segue;
2. le operazioni solide di tutti i giorni (estrudi, rivoluzione, guscio, raccordi, fori, serie);
3. **assiemi** che si muovono e si controllano (giunti, interferenze);
4. **disegni tecnici** per l'officina (viste, quote, PDF/DXF) e **STEP** per i fornitori;
5. lamiera con sviluppo per il laser e stampa 3D a colori, come oggi.

**Criterio di fine mese:** rifare da zero in CAD Takeoff tre pezzi veri del progetto 025 RobotVolley
(una parte tornita, una lamiera, un piccolo assieme), con quote modificabili, tavola PDF e STEP, e
passarli a un fornitore senza usare Fusion.

## 2. Dove siamo

Livello per area, da 0 (assente) a 5 (come Fusion per l'uso di Ross).

| Area | Oggi | Livello |
|---|---|---|
| **Schizzo** | Linee, rettangoli, cerchi, poligoni, asole; aggancio a vertici, punti medi e centri; schizzo su faccia e su piani sfalsati; **profili a regioni** (anelli con foro, più aree) | 2 |
| **Solidi** | Estrudi (nuovo/unisci/taglia/interseca, su faccia, con fori), box/cilindro/prisma; Foro (lamato, svasato, filettatura indicata); Raccordo/smusso (dritti, circolari, coni, archi, catena tangente); **Premi/Tira** su più facce; serie, specchio, dividi | 2,5 |
| **Motore geometrico** | B-rep per le primitive, booleane poligonali veloci con identità delle facce; superfici descritte (piano, cilindro, cono, toro) ma la geometria di verità è sfaccettata (64 segmenti) | 2 |
| **Storico parametrico** | Timeline con marker, soppressione e modifica dei passi; annulla/ripeti; estrusioni collegate allo schizzo | 2,5 |
| **Assiemi** | Componenti da altri file, posizione e rotazione, distinta base CSV | 1,5 |
| **Lamiera** | Piastra e flange sui 4 lati, materiali con regole da pressa, angoli chiusi, sviluppo e DXF con fori | 2,5 |
| **Disegni tecnici 2D** | — | 0 |
| **Scambio file** | Export STL, 3MF a colori, DXF sviluppi; import STL/OBJ/3MF; da Fusion interi progetti (mesh) con l'add-in e lo script | 1,5 |
| **Interfaccia** | Ribbon tipo Fusion, schede dei disegni, Home con progetti e cartelle, menu col tasto destro, frecce ed etichette modificabili, ViewCube | 3 |
| **Prestazioni** | Booleane per coppie reali di poligoni; assieme da 1 M triangoli aperto in ~3 s in background | 3,5 |
| **AI** | 27 strumenti (anche export STEP, tavola PDF, parametri); chat interna (API) e Claude Desktop (abbonamento) via MCP | 3 |
| **Qualità e distribuzione** | CI, test del motore, TestFlight, GitHub AGPL, versione automatica | 4 |

## 3. Cosa manca, per area (dal più grave)

**Schizzo — il buco principale.** Senza vincoli e quote non è un CAD parametrico:
- risolutore di vincoli: coincidente, orizzontale/verticale, parallelo, perpendicolare, tangente,
  uguale, concentrico, simmetrico, fisso; stato «completamente vincolato»;
- quote pilotanti sul canvas (lunghezza, raggio/diametro, angolo, distanza) che si modificano con un clic;
- archi (3 punti, tangente, centro), raccordo e smusso 2D, taglia/estendi, offset, specchio, spline.

**Solidi:**
- rivoluzione, guscio, sformo, nervatura;
- estrusione simmetrica, «fino a faccia», rastremata;
- piani, assi e punti di costruzione (inclinati, per tre punti, tangenti);
- **raccordi d'angolo** dove si incontrano tre raccordi (oggi il solido resta aperto: visto sull'auto);
- sposta/ruota corpi, serie e specchio di *feature*, sweep, loft, filetto modellato.

**Motore:**
- la verità geometrica è sfaccettata: servono curve e superfici esatte (almeno analitiche:
  piano, cilindro, cono, sfera, toro) con tassellazione solo per la vista;
- tolleranze;
- riferimenti a facce e spigoli che sopravvivono alle modifiche a monte.

**Storico:** parametri utente ed espressioni (`larghezza/2 + 3`), tabella parametri, riferimenti robusti
quando si modifica un passo vecchio.

**Assiemi:** giunti (rigido, rotoidale, prismatico, cilindrico), movimento, interferenze, vista esplosa,
modifica di un componente nel contesto dell'assieme.

**Disegni:** tavola A4/A3 ISO (primo diedro), viste ortogonali, isometrica e sezioni, linee nascoste,
quote, cartiglio, export PDF e DXF.

**Scambio:** STEP in uscita e in entrata (lo standard dei fornitori), DXF di schizzi e facce, storico
parametrico da Fusion (non solo mesh).

**Interfaccia:** misura, sezione dinamica, stili di vista, unità e preferenze, marking menu completo.

## 4. Priorità

| Priorità | Cosa | Perché |
|---|---|---|
| **P0** | Schizzo vincolato e quotato; archi e raccordi 2D; parametri ed espressioni | È la base di ogni pezzo vero: senza, ogni modifica si rifà a mano |
| **P0** | Rivoluzione, guscio, piani di costruzione, raccordi d'angolo corretti | Le operazioni che mancano più spesso nei pezzi del RobotVolley |
| **P1** | Disegni tecnici con PDF/DXF; export STEP | Senza tavole e STEP non si va dal fornitore |
| **P1** | Giunti e interferenze negli assiemi; misura e sezione | Controllare che il robot si monti e si muova |
| **P2** | Lamiera avanzata (flangia su spigolo qualsiasi, orli, scarichi tondi), import STEP, sweep/loft | Molto utile, ma dopo le basi |
| **P3** | Filetto modellato, superfici libere (NURBS), import parametrico da Fusion, simulazione, CAM | Mesi 2–3 e oltre |

## 5. Piano delle 4 settimane

Ogni settimana si chiude con CI verde, push su GitHub, **build TestFlight** e una prova di Ross il venerdì
su un pezzo reale. Ogni consegna ha test automatici sul motore.

### Priorità decisa con Ross il 27/09: import modificabile da Fusion 360

Il lavoro di Ross è nei server di Autodesk: senza portarlo **modificabile** (non come mesh) CAD
Takeoff non può sostituire Fusion. Il plug-in legge la cronologia dentro Fusion e CAD Takeoff la
ricostruisce; ogni corpo ricostruito è confrontato con quello di Fusion (volume e ingombro) e,
se differisce, entra la mesh al suo posto: niente si perde e niente è sbagliato.
1. **Fatto 27/09** — convertitore in CADCore (parametri utente con espressioni, schizzi con vincoli
   e quote, estrusioni distanza/simmetrica/passante, rivoluzioni, raccordi e smussi ritrovati per
   geometria, fori, gusci); plug-in e script di progetto scrivono la cronologia nel .ftk; le facce
   delle estrusioni prendono il nome dalle curve dello schizzo (una quota cambiata non fa perdere
   raccordi e smussi).
2. Prova di Ross su pezzi veri di «025 RobotVolley»: dal resoconto all'apertura si vede cosa non
   passa ancora; si allarga il convertitore caso per caso (estrusione a due lati o da faccia, serie
   e specchi, combina, fori svasati, sformo, loft/sweep come mesh).
3. Componenti usati più volte e giunti dell'assieme; poi riaprire in CAD Takeoff un file già
   convertito e riesportato da Fusion senza perdere le modifiche fatte qui.

### Settimana 1 (29 set – 3 ott) — Schizzo parametrico

**Stato al 26/09 (in anticipo): fatta, in attesa della prova di Ross.** Vincoli con risolutore e gradi di
libertà, quote sul canvas, vincoli automatici, profili a regioni, archi, raccordo e smusso 2D, Taglia,
Estendi, Offset (anche di catene raccordate), Specchio con vincolo Simmetrico, Parametri utente ed
espressioni (quote dello schizzo e misure di box, cilindro, estrusione). Cambiare una quota muove solo
la geometria che la riguarda. Poi anche spline e tangenza automatica tra archi e linee: settimana 1
completa.
- Risolutore di vincoli nostro (Newton–Raphson smorzato con analisi dei gradi di libertà), vincoli
  automatici mentre si disegna (orizzontale, verticale, coincidente, tangente), colore dello stato:
  blu = libero, nero = vincolato.
- Quote pilotanti sul canvas con modifica diretta; parametri utente ed espressioni.
- Archi, raccordo/smusso 2D, taglia/estendi, offset, specchio.
- *Accettazione:* staffa a L disegnata con quote; cambio una quota da 40 a 60 e il solido estruso segue.

### Settimana 2 (6 – 10 ott) — Solidi di tutti i giorni

**Stato al 27/09 (in anticipo), in attesa della prova di Ross:** fatti Rivoluzione, Guscio,
estrusione simmetrica e con sformo, Sposta/ruota corpi, piani di schizzo inclinati; raccordi e smussi
su tutti gli spigoli danno solidi chiusi (auto sportiva: da R0,8 a R8), anche lungo cilindri che
incontrano un piano; angoli sferici dove tre raccordi si incontrano (come Fusion).
Poi anche «fino a faccia», serie/specchio di feature (un foro ripetuto) e piani di costruzione per
tre punti, tangenti a cilindri/coni/sfere e medi fra due facce. Resta: superfici esatte come verità
del motore.
- Rivoluzione, guscio, estrusione simmetrica / fino a faccia / rastremata.
- Piani, assi e punti di costruzione.
- Raccordi d'angolo (sfera dove si incontrano tre raccordi): niente più solidi aperti.
- Sposta/ruota corpi, serie e specchio di feature.
- Motore: superfici esatte per piano, cilindro, cono, sfera e toro come verità, con tassellazione a
  risoluzione di vista.
- *Accettazione:* il perno forcella TKP-202 e un coperchio stampato col guscio rifatti con quote.

### Settimana 3 (13 – 17 ott) — Verso il fornitore

**Stato al 27/09:** export STEP AP214 fatto (un solido per corpo con colori; piani, cilindri, coni e
tori esatti, il resto sfaccettato), verificato con OpenCascade. Tavola tecnica v1 fatta: viste ISO
primo diedro con linee nascoste, isometrica, quote d'ingombro, diametri e assi, cartiglio; PDF e DXF.
Vista in sezione A-A con tratteggio. Nello STEP anche le sfere: un box raccordato esce tutto esatto.
Settimana 4 anticipata in parte: controllo interferenze. Poi le quote messe negli schizzi finiscono
sulla tavola, nella vista che vede lo schizzo in vero (senza ripetere quelle d'ingombro). Resta:
spostare o aggiungere a mano quote sulla tavola.
- **Export STEP AP214** scritto da noi: facce analitiche esatte, sfaccettato come riserva.
- **Disegni tecnici v1:** tavola A4/A3 ISO, viste ortogonali e isometrica, linee nascoste, quote lineari,
  radiali e di foro, cartiglio, export PDF e DXF.
- *Accettazione:* un fornitore (o uno dei suoi programmi) apre lo STEP; tavola PDF stampabile di una parte
  lavorata al tornio.

### Settimana 4 (20 – 24 ott) — Assiemi e lamiera

**Stato al 27/09:** fatti controllo interferenze, giunti (rigido, rotazione, scorrimento, cilindrico),
vista esplosa, misura, sezione dinamica nel viewport; lamiera con risvolti (profilo a C e a Z) e orli
a 180°, tavola di piega PDF/DXF con sviluppo quotato e tabelle pieghe e fori; nello sviluppo anche i
tagli da schizzo (finestre, asole) e le tacche sul bordo; base di forma qualsiasi da un profilo
dello schizzo con flange (e risvolti) su qualunque lato dritto, scelti col clic sul pezzo, sviluppo
con pieghe, fori e tagli. Restano: flange su lati di spigoli successivi (una flangia sopra l'altra),
scarichi tondi, trascinamento dei giunti.

- Giunti (rigido, rotazione, scorrimento) con trascinamento, controllo interferenze, vista esplosa.
- Lamiera: flangia su qualsiasi spigolo, orli, scarichi tondi.
- Misura e sezione dinamica.
- Stabilizzazione: TestFlight **0.2** ai colleghi.
- *Accettazione:* la forcella RBTV-200 montata con giunto di rotazione, senza interferenze; una lamiera
  del corpo del robot con lo sviluppo per il laser.

### Dopo il mese (novembre–dicembre)
Import STEP, sweep/loft, sformo e nervature, filetto modellato, superfici libere, import parametrico
da Fusion, cronologia delle versioni dei file, poi eventualmente simulazione e CAM.

## 6. Rischi e decisioni per Ross

1. **Motore tutto nostro (decisione del 25/09).** Resta valida e il piano la rispetta. La conseguenza da
   sapere: STEP in uscita con geometria analitica esatta è alla nostra portata nel mese; **STEP in entrata
   con superfici libere (NURBS)** e i raccordi più complessi richiedono più tempo di quanto richiederebbe
   una libreria esterna come OpenCascade. Se in futuro l'import STEP diventasse urgente, è l'unico punto
   in cui varrebbe la pena riconsiderare la decisione: lo decidi tu.
2. **Il risolutore di vincoli è il pezzo più rischioso** (stabilità, schizzi sovra-vincolati): per questo
   è in settimana 1, con test su casi classici e una settimana di margine distribuita nelle successive.
3. **Un mese è stretto per «come Fusion» su tutto.** Il piano punta a essere *professionale per i pezzi
   di Ross*: se una settimana slitta, si sacrifica prima la lamiera avanzata (P2), mai lo schizzo vincolato.
4. **Da Ross servono:** i tre pezzi di riferimento del RobotVolley da usare come prova; le norme per le
   tavole (ISO, primo diedro, cartiglio Takeoff); la prova del venerdì sulla build TestFlight.

## 7. Come lavoriamo

- Un passo alla volta, ognuno committato con test (+1 alla versione a ogni commit), CI verde, push.
- Venerdì: build TestFlight e nota di rilascio breve per Ross.
- Il criterio di fine mese (sezione 1) è la misura del risultato, non il numero di funzioni.
