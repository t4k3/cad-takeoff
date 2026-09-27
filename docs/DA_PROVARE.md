# Da provare (Ross) — novità dal 26/09

Build: riapri l'app (o TestFlight quando esce). Ogni punto ha i test automatici sul motore; queste
sono le prove a mano, sull'interfaccia.

## Schizzo
- [ ] **Arco** (A): inizio, fine, punto sull'arco. **Spline** (B): punti, Invio o clic sul primo punto.
- [ ] **Raccordo** e **Smusso** su un angolo (raggio/distanza nelle OPZIONI); cambia la quota R: i lati restano fermi.
- [ ] **Taglia** (T): il pezzo sotto il cursore diventa rosso, clic lo toglie. **Estendi**: clic vicino a un estremo.
- [ ] **Offset** (O): clic sulla forma, poi sul lato. Prova su un rettangolo raccordato.
- [ ] **Specchio**: clic sulla linea d'asse, poi sulle forme; sposta l'originale, la copia segue.
- [ ] Vincolo **Simmetrico** (VINCOLI): due punti e la linea.
- [ ] **Parametri** (ƒ): crea `larghezza = 40`, scrivi `larghezza / 2` in una quota → «fx:»; cambia il parametro.
- [ ] Arco disegnato dalla fine di una linea nella sua direzione: tangenza automatica.
- [ ] Piano di schizzo **inclinato** (campo «Inclina» nella scelta del piano).
- [ ] Piani di costruzione: **3 punti** (vertici/centri/punti medi), **Medio** fra due facce parallele, clic su un cilindro → piano **tangente**.

## Solidi
- [ ] **Rivoluzione** (Schizzo › CREA): aree + linea d'asse (meglio di costruzione), angolo, verso.
- [ ] **Estrudi**: Estensione Simmetrica / **Passante**; **Sformo** in gradi; anche nella distanza un'espressione.
- [ ] **Guscio** (SOLIDO › MODIFICA): clic sulla faccia sopra di una scatola, spessore.
- [ ] **Sposta**: corpo selezionato, X/Y/Z e rotazione.
- [ ] **Serie/Specchio** con un foro o un taglio selezionato: ripete l'operazione.
- [ ] **Raccordo su tutti gli spigoli** dell'auto: solidi chiusi; angoli sferici sui box.

## Assiemi
- [ ] **Giunto**: bordo del foro sul pezzo che si muove, poi dove va; Rotazione, angolo.
- [ ] **Interferenze** e **Esplosa** (ASSIEME).
- [ ] **Misura**: due facce/spigoli → distanza minima; un bordo tondo → Ø.

## Verso il fornitore
- [ ] **STEP** (STAMPA › STEP): aprilo in Fusion — fori, perni, raccordi devono essere superfici vere.
- [ ] **Tavola** (STAMPA › Tavola, ⇧⌘P): PDF o DXF; casella «in sezione» per i torniti; tabella fori.
- [ ] **Tavola di piega** (LAMIERA › SVILUPPO › Tavola): sviluppo quotato, pieghe P1… su/giù, tabelle pieghe e fori.
- [ ] **Risvolto / orlo** (Lamiera › «Sulla punta»): profilo a C, a Z, orlo 180°; scatola con risvolti → scarichi negli angoli dello sviluppo.
- [ ] **Tavola con le quote degli schizzi**: quota due fori in uno schizzo (distanza orizzontale), estrudi, STAMPA › Tavola: la quota compare nella vista dall'alto.
- [ ] **Tornito**: profilo su XZ con quote dall'asse, Rivoluzione, Tavola (anche «in sezione»): le quote dall'asse escono come Ø.
- [ ] **Tagli nello sviluppo**: schizzo su una faccia della lamiera, rettangolo/asola, Estrudi in taglio Passante: la finestra compare nello sviluppo, nel DXF e nella tavola di piega.
- [ ] **Sezione** (barra in basso, forbici): piano in squadro a X/Y/Z, cursore per spostarlo, «Tieni l'altra metà»; l'interno tagliato è arancio.
- [ ] **Giunto trascinabile**: nel comando Giunto (e modificandolo) una freccia sull'asse: trascinala per girare (Rotazione) o far scorrere (Scorrimento).
- [ ] **Schizzo più facile**: la linea si aggancia ai lati e ai cerchi (◇), agli incroci (×), si allinea in orizzontale/verticale coi punti già disegnati (guida tratteggiata); si finisce con doppio clic, Esc o cambiando strumento.
- [ ] **Vincoli sotto un pulsante** (Schizzo › VINCOLI › Vincoli): la lista si apre sotto, un clic per scegliere.
- [ ] **Schizzo su una faccia qualsiasi**: SOLIDO › Schizzo, passa sulle facce (si illuminano), clic su una piana anche di smussi/STL; selezione ora arancio pieno con contorno spesso.
- [ ] **Pezzi importati da Fusion**: facce piane intere (schizzo su faccia, punto medio dei bordi), fori e perni riconosciuti come cilindri (misura Ø, centro, giunto, piano tangente). Reimporta il pezzo o riapri il file.

## Import modificabile da Fusion (nuovo)
- [ ] Reinstalla il plug-in dall'app (Home › «Installa add-in…»): copia anche `fusion_history.py`. In Fusion riavvia l'aggiunta.
- [ ] Un pezzo semplice (schizzo quotato + estrusione + raccordo): «Esporta per CAD Takeoff», aprilo qui. Nella barra di stato: «Da Fusion: N corpi modificabili…». Doppio clic sullo schizzo: quote e vincoli ci sono; cambia un parametro in «Parametri».
- [ ] Rilancia lo script «Importa progetto in CAD Takeoff» su «025 RobotVolley»: riesporta tutto (i vecchi .ftk senza cronologia non vengono saltati). Mandami import-fusion.txt e i messaggi «non convertiti» dei pezzi che ti servono.

## Export più liscio per la stampa
- [ ] Esporta STL o 3MF: nel pannello «Qualità fine: curve lisce» (predefinita, ricordata) — un cilindro o un raccordo grande nello slicer non mostra più le faccette; «Qualità normale» = come prima. Il modello a schermo non cambia.

## Tavola a schermo
- [ ] ⇧⌘P (o CREA/ESPORTA › Tavola): si apre la tavola come verrà stampata. Quota (D): clic su un estremo o metà di uno spigolo (i punti agganciabili si accendono), clic su un secondo punto della stessa vista, poi clic sopra/sotto (quota orizzontale), a lato (verticale) o in mezzo / con ⌥ (allineata). Seleziona: clic su una quota, trascinala per allontanarla o avvicinarla, Canc la toglie (una automatica torna con «Ripristina quote automatiche»). ⌘Z annulla. Esporta… → PDF o DXF con le stesse quote; chiudi e riapri il disegno: le quote restano.

## Giunti trascinabili
- [ ] Assieme con un giunto di Rotazione: clic sul pezzo che si muove (selezionato), poi trascinalo: gira attorno all'asse seguendo il mouse (gradi interi, valore nella barra in basso); al rilascio un passo solo di ⌘Z. Scorrimento: scorre lungo l'asse. Cilindrico: gira, con ⌥ premuto scorre. Trascinare altrove (o un pezzo non selezionato) gira la vista come sempre.

## Lamiera a base libera
- [ ] Schizzo sul piano XY → un profilo chiuso (esagono, forma a L…) → CREA › **Lamiera**: esce la base piana; clicca i bordi da piegare (di nuovo per toglierli), altezza/angolo/risvolto come sempre → OK. LAMIERA › Sviluppo: la sagoma stesa con le pieghe. Due lati piegati che si incontrano in un angolo rientrante: messaggio che si sovrappongono. Un solo lato piegato che finisce in un angolo rientrante (la L): la flangia si ferma uno spessore prima e nello sviluppo c'è la fessura con il fondo tondo che la stacca dalla base.

## Circuiti (1.0.0)
- [ ] Scheda **CIRCUITI** › Esempio: scheda verde, piazzole oro (sopra) e blu (sotto), sigle, linee bianche dei collegamenti da sbrogliare; passa sulle piazzole: la rete si accende in arancio.
- [ ] Trascina un componente (anteprima dal vivo, collegamenti che seguono), R ruota, F cambia lato; ⌘Z annulla una mossa alla volta.
- [ ] VERIFICHE a destra: clic su un problema → seleziona il componente. PRODUZIONE › JLCPCB: se manca qualcosa il messaggio dice cosa (l'esempio ha componenti fittizi: non ordinare).
- [ ] Nuovo / Salva / Apri (.ftkc); chiudendo con modifiche chiede se salvare.
- [ ] **Costruire un circuito** (CIRCUITI › CREA): Componente → scegli, sigla/valore → clic sulla scheda (resta attivo per R2, R3…; Esc finisce). Collega → clic su una piazzola, poi su un'altra: compare la linea del collegamento. Scheda → misure con anteprima tratteggiata. Elimina (o Canc). Ogni passo si annulla con ⌘Z. Nota: da «Nuovo» la libreria è vuota finché Codex non consegna i modelli generici; intanto prova sull'Esempio.
- [ ] **Librerie** (CIRCUITI › LIBRERIA): Importa un .kicad_mod / .kicad_sym (scegli il simbolo) / EasyEDA .json → anteprima e avvisi → Importa. Poi «Nuovo tipo»: simbolo + impronta, controlla pin → piazzole, Crea → lo trovi in CREA › Componente.
- [ ] **Assistente sul Mac** (pannello Assistente › fornitore «Apple Intelligence — sul Mac, senza rete»): «Crea un cubo di 20 mm di lato» → cubo creato, annullabile. Niente chiave API. Se Claude/ChatGPT non hanno la chiave parte già su questo.
- [ ] **Schema** (CIRCUITI › Schema): Componente → clic sul foglio (il primo foglio nasce da solo); Filo: clic su un pin (□), clic nel vuoto per le pieghe, clic sull'altro pin; Etichetta su un pin → nome (VCC…); NC; Giunzione su un filo. Seleziona e trascina un simbolo, R ruota, M specchia, Canc elimina. Poi PCB: «N da posare dallo schema» → clic sulla scheda: compaiono i collegamenti. Fogli dal menu in alto.
- [ ] **Piste** (CIRCUITI › PCB › SBROGLIO): Pista (X) → clic su una piazzola collegata → clic per le pieghe (45°, / cambia la piega) → clic sulla piazzola della stessa rete: la linea bianca sparisce. Il tratto verso il mouse è rosso con «Non confermabile» se tocca un'altra rete o esce dalla scheda. V (o il menu Strato) mette una via e continua sull'altro lato; ⌫ toglie l'ultimo punto, Invio finisce, Esc annulla. Clic su una pista: nel pannello rete, strato, lunghezza e larghezza (cambiabile); Canc la elimina; ⌘Z. Scheda: strati (2…32, solo senza rame) e regole. Gli errori del rame compaiono in VERIFICHE e sulla scheda (×); un clic sull'errore lo cerchia.
- [ ] **Classi e aree vietate** (CIRCUITI › PCB › SBROGLIO): Classi → «Potenza» (+) → pista 0,5 mm, via 0,8/0,4 → Applica; nella colonna RETI metti una rete in Potenza: una Pista su quella rete parte da 0,5 mm e le via sono 0,8/0,4 (barra in basso). Cambia un minimo sopra il rame già tracciato: prima di Applica dice quanti errori crea. Chiudi con modifiche non applicate: chiede Applica/Scarta/Annulla. Area vietata (K) → due clic e Invio = rettangolo (o più clic e clic sul primo punto); se copre una pista, prima di confermare dice «conflitti col rame». Passa sopra un'area: si illumina in arancio; clic la seleziona (nome, strati, cosa vieta), trascinala, Canc la elimina. Una pista dentro un'area è rifiutata.
- [ ] **Piani di rame** (CIRCUITI › PCB › SBROGLIO › Piano, tasto P): scegli la rete in basso (o parti cliccando su una piazzola: ne prende la rete) → clic sugli angoli; due clic e doppio clic (o Invio, o Chiudi) = rettangolo. Prima di confermare vedi già il riempimento del motore, lontano dalle altre reti, dai fori, dal bordo e dalle aree vietate. Clic dentro il piano lo seleziona (nome, rete, strato, «Togli le isole», area del rame); trascinalo, Canc lo elimina, ⌘Z. Due piani di reti diverse sovrapposti sullo stesso strato: rifiutato, la bozza resta. Esc mentre il motore lavora annulla senza aggiungere nulla. Collegamento pieno: termiche e colli minimi non ci sono ancora.
