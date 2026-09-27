# Piani di rame — contratto T94

Terzo traguardo, 27/09/2026. Motore Swift proprietario; 124 test elettronici e cinque lettori
indipendenti PASS. Aggancio T97 di Claude nella build **1.0.33**, CI **16/16 PASS**.
Collaudo visivo ancora da eseguire: [VALIDATION.md](VALIDATION.md).
Non è ancora una qualificazione per fabbricare PCB.

## Dati e comandi

- `PCBCopper.zones: [PCBZone]`, vuoto nei file precedenti.
- `PCBZone(id:name:netID:layer:outline:removeIslands:)`: un solo strato, rete obbligatoria,
  contorno semplice anche concavo (3–1024 punti), chiusura implicita. `removeIslands`
  predefinito true. Nome iniziale «Piano di rame»; identità creata all'inizio del draft.
- `PCBCommand.addZone`, `updateZone`, `removeZone(UUID)`, `moveZone(id:offset:)`; batch,
  preview e revisione attesa come gli altri comandi. Un'azione, un passo annullabile.
- `PCBKeepout.zones: Bool`, predefinito true; le vecchie aree vietate proteggono anche i
  piani. Il pannello deve esporre una quarta casella «Piani» indipendente da Piste/Via/Piazzole.
- Documento **6**, lettura **1–6** con migrazione dell'intero storico. Le versioni precedenti
  devono rifiutare il file. Si salva il contorno e le regole, mai una cache di rame da fidarsi.

## Riempimento e connettività

Il motore ritaglia l'intersezione piano/scheda, mantiene la distanza dal bordo,
sottrae il rame di altre reti (o senza rete), i fori e le aree vietate. La clearance è
il massimo delle regole delle due reti; anche le classi vengono rispettate. Le connessioni
alla stessa rete sono **piene**, senza termiche. Modificare piste, componenti, regole o
keepout ricalcola il piano nello snapshot: il rame derivato vecchio non blocca una nuova pista.

Scomposizione verticale poligonale propria: eventi ai vertici e alle intersezioni, celle
convesse con interni disgiunti. Nessuna griglia raster. Ostacoli arrotondati approssimati
verso l'esterno, con sovrataglio radiale fino a 0,005 mm e guardia numerica 0,000001 mm;
il piano non riduce la clearance richiesta. Ricalcolo cancellabile in background.
Limiti di complessità espliciti bloccano il riempimento senza risultati parziali.

Le celle dello stesso piano **non** sono connesse solo perché condividono l'UUID:
devono toccarsi nel rame. Piste, piazzole e via passanti concorrono alla connettività.
`removeIslands` elimina le componenti prive di un percorso fisico verso una piazzola;
una via sola non basta. Senza rimozione vengono conservate e diagnosticate. Un piano
vuoto rimane modificabile, ma non riduce le airwire né costituisce un bersaglio del routing.

Piani di reti diverse sullo stesso strato devono avere contorni separati: sovrapposizione
rifiutata con `overlapping_zone_nets`. Nessuna priorità elettrica decisa in base all'UUID.
Sono ammessi piani sovrapposti della stessa rete e piani distinti su strati diversi.

## Contratto con l'app

- `PCBSnapshot.zones: [PCBZoneFill]`, ordinati per UUID; ogni elemento contiene `zone`,
  `cells: [[PCBPoint]]`, `islandCount`, `removedIslandCount`, `area` in mm².
- `PCBItem.zone(UUID)` è un nuovo caso: aggiornare gli switch esaustivi dell'app.
  Le celle mantenute sono anche in `snapshot.primitives`, raggio zero, contorno CCW.
  Disegnarle senza contorni interni e sotto piste/pad, una sola volta; il contorno del
  piano è un oggetto distinto dalla superficie riempita. Colori e trasparenza spettano alla UI.
- `snapshot.pickZones(point:tolerance:layer:)` seleziona i **contorni modificabili**,
  anche vuoti. `snapshot.pick(...)` e `snapTargets(...)` vedono solo il **rame presente**:
  usarli per iniziare/finire il routing. Il punto agganciato interno al piano è il punto
  richiesto, non il centro di una cella della scomposizione.
- Stato/preview/worker devono restare legati a identità documento, revisione e sessione.
  Conferma con lo stesso UUID/comando dell'anteprima; niente ricostruzione geometrica nella UI.
  Anche `apply` ricalcola il rame: eseguirlo in un worker, mantenendo il draft fino al successo,
  e installare il documento risultante solo se identità e revisione coincidono ancora.
  Segnalare operazione in corso, impedire conferme duplicate e consentire annullamento.
- Mostrare rete, strato, rimozione isole e «Collegamento pieno»; esplicitare che termiche
  e larghezza minima dei colli non sono ancora disponibili. Un'area senza pad collegato
  può risultare vuota: mostrare `pcb_zone_empty` con il piano selezionabile.

## Limiti e fonti di studio

Prova sintetica Release su questo Mac: 100 ostacoli, 1.441 celle, snapshot 35,91 ms;
pick + pickZones + snap p95 0,0234 ms. Debug: 401,49 ms e 0,1812 ms.
Non sono garanzie per qualsiasi scheda: valgono i worker cancellabili e i limiti espliciti.

Esclusi termiche, verifica della larghezza minima dei colli, riempimento reticolato,
priorità tra reti sovrapposte, mask/paste, Gerber e certificazione del produttore.
Area esposta per singolo piano: piani della stessa rete sovrapposti non vanno sommati
per ottenere il consumo totale di rame.

Studio del comportamento: [manuale ufficiale KiCad 9](https://docs.kicad.org/9.0/it/pcbnew/pcbnew.html),
sezioni zone, connessioni solide/termiche e rimozione isole. Nessun codice o libreria KiCad
incorporati; l'algoritmo e la rappresentazione sono implementati nel package.
