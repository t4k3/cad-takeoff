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

## Circuiti (1.0.0)
- [ ] Scheda **CIRCUITI** › Esempio: scheda verde, piazzole oro (sopra) e blu (sotto), sigle, linee bianche dei collegamenti da sbrogliare; passa sulle piazzole: la rete si accende in arancio.
- [ ] Trascina un componente (anteprima dal vivo, collegamenti che seguono), R ruota, F cambia lato; ⌘Z annulla una mossa alla volta.
- [ ] VERIFICHE a destra: clic su un problema → seleziona il componente. PRODUZIONE › JLCPCB: se manca qualcosa il messaggio dice cosa (l'esempio ha componenti fittizi: non ordinare).
- [ ] Nuovo / Salva / Apri (.ftkc); chiudendo con modifiche chiede se salvare.
- [ ] **Costruire un circuito** (CIRCUITI › CREA): Componente → scegli, sigla/valore → clic sulla scheda (resta attivo per R2, R3…; Esc finisce). Collega → clic su una piazzola, poi su un'altra: compare la linea del collegamento. Scheda → misure con anteprima tratteggiata. Elimina (o Canc). Ogni passo si annulla con ⌘Z. Nota: da «Nuovo» la libreria è vuota finché Codex non consegna i modelli generici; intanto prova sull'Esempio.
- [ ] **Librerie** (CIRCUITI › LIBRERIA): Importa un .kicad_mod / .kicad_sym (scegli il simbolo) / EasyEDA .json → anteprima e avvisi → Importa. Poi «Nuovo tipo»: simbolo + impronta, controlla pin → piazzole, Crea → lo trovi in CREA › Componente.
- [ ] **Assistente sul Mac** (pannello Assistente › fornitore «Apple Intelligence — sul Mac, senza rete»): «Crea un cubo di 20 mm di lato» → cubo creato, annullabile. Niente chiave API. Se Claude/ChatGPT non hanno la chiave parte già su questo.
