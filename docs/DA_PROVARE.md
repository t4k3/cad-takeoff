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
