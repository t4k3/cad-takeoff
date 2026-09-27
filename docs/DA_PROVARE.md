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
