# Regole UX di CAD Takeoff

Vincolanti per chiunque scriva codice che l'utente vede o che la UI usa (Claude, Codex, assistente).
Nascono dalle richieste di Ross; quando una regola cambia, si cambia qui e si annota in
`docs/COLLAB.md`. Riferimento di stile: **Fusion 360**, ma più semplice. Utente tipo: progettista
meccanico/elettronico su un **MacBook 13"**, che vuole lavorare senza leggere istruzioni.

## 1. Principi

1. **Si vede prima di fare.** Ogni comando mostra un'anteprima dal vivo; ciò che il clic sceglierà
   si illumina *prima* del clic (faccia, spigolo, piazzola, pista, rete).
2. **Un'azione = un passo di annulla.** OK conferma tutto in un solo passo (⌘Z lo toglie intero);
   Esc annulla il comando senza lasciare tracce. Vale anche per l'assistente e per MCP.
3. **Niente vicoli ciechi.** Un comando non chiede mai «premi Invio per finire»: si finisce anche
   con doppio clic, con Esc (che **tiene** quanto già fatto se ha senso, es. una linea) o scegliendo
   un altro strumento. Chiudere/uscire non perde lavoro.
4. **Il modello non si rompe mai in silenzio.** Se qualcosa non riesce si dice cosa e perché, in
   italiano, con il soggetto selezionabile («Pista 12: 0,15 mm dalla piazzola U3-4, minimo 0,2»).
5. **Stesse azioni per mano, assistente e MCP**: un solo catalogo di comandi tipizzati, le stesse
   transazioni, lo stesso annulla.

## 2. Layout (13")

- Barra a schede in alto (SOLIDO, SCHIZZO, LAMIERA, STAMPA…; in futuro SCHEMA, PCB): una scheda
  compare solo quando serve (SCHIZZO solo mentre si disegna).
- Ogni scheda ha gruppi con etichetta (DISEGNA, MODIFICA, VINCOLI…). Pulsanti icona+etichetta
  corta (1 parola). **Ciò che si usa poco sta dietro un pulsante con lista a comparsa** (es. i 10
  vincoli): la barra non deve uscire dallo schermo su 13". Se proprio non ci sta, scorre.
- Pannello del comando (`CommandSession`): titolo, campi, anteprima, OK/Annulla. Campi numerici che
  accettano **espressioni e parametri** (`larghezza / 2`). Il campo attivo di scelta (es. «Asse»,
  «Faccia») riceve i clic del viewport.
- Barra di stato: una riga, risultato dell'azione («Tavola salvata: …», «Da Fusion: 5 corpi
  modificabili…»). Niente muri di testo, niente finestre modali per informare.
- Browser a sinistra (cronologia/oggetti), Parametri/Assistente a destra, ripiegabili.

## 3. Puntatore, selezione, agganci

- **Freccia** quando il clic sceglie qualcosa; **crocetta** solo quando il clic piazza un punto
  (disegno, centri, instradamento di una pista). Il cambio è immediato.
- Selezione: **arancio pieno** con contorno spesso; il sotto-cursore più tenue. Mai sbiadito.
- Filtro di selezione esplicito (Corpo/Faccia/Spigolo; in elettronica Componente/Piazzola/Pista/
  Rete). Shift/⌘ aggiunge.
- Agganci con simboli (□ vertice, △ punto medio, ○ centro, × incrocio, ◇ sulla curva) e guide di
  allineamento tratteggiate. I punti vincono sulle linee e si prendono da un po' più lontano; la
  griglia vale solo dove non c'è niente di meglio. Raggio d'aggancio costante sullo schermo (~11 pt).
- Tutto ciò che è selezionabile ha un'**identità stabile** (UUID/ID persistente), mai un indice:
  sopravvive a modifiche, annulla e riapertura, e permette la selezione incrociata (schema ↔ PCB ↔
  3D, errore ↔ oggetto).

## 4. Tempi

- Hover e agganci: < 5 ms per evento. Anteprima di un comando: < 50 ms, altrimenti in background
  con l'ultima anteprima valida a schermo.
- Operazioni lunghe (apertura grande assieme, DRC completo, export): in background con
  avanzamento e possibilità di interrompere; la UI non si blocca mai.

## 5. Parole

- UI in **italiano**, frasi brevi all'infinito o all'imperativo («Clicca una faccia»). Unità mm e
  gradi, virgola decimale a schermo, fino a 2 decimali. Nomi automatici leggibili («Estrusione 3»,
  «R1», «Rete GND»).
- Messaggi d'errore: cosa non va + cosa fare. Mai stack trace o nomi di tipi Swift.

## 6. Cosa deve dare un motore alla UI (contratto per chi scrive il core)

Un motore (CADCore, ElectronicsCore, …) è pronto per l'aggancio quando offre, **senza** che la UI
debba ricalcolare geometria o regole:

1. **Comandi tipizzati e transazionali** con `expectedRevision`: applica tutto o niente; stesso
   catalogo per UI, assistente e MCP.
2. **Anteprima**: eseguire un comando su una copia (o in modo non distruttivo) e restituire il
   risultato da disegnare, senza toccare lo storico.
3. **Primitive da disegnare** in mm nel sistema del documento: poligoni/polilinee/cerchi con
   livello o strato, stile semantico (rame, serigrafia, contorno, rete evidenziata…) e l'ID
   dell'oggetto a cui appartengono. I colori li decide la UI.
4. **Scelta sotto il cursore** (`pick(point, tolleranza, filtro) → [ID]` ordinati per priorità) e
   **punti d'aggancio** (`snapTargets(vicino a, raggio) → [(punto, tipo, ID)]`), veloci (indice
   spaziale), deterministici.
5. **Diagnostica** come dati: livello, messaggio italiano, **ID dei soggetti**, posizione, eventuale
   correzione proposta (anch'essa un comando).
6. Identità stabili, errori che non alterano il documento, niente I/O o rete implicita, niente
   dipendenze UI. Test headless che coprono ciò che la UI promette (come `scripts/test-sketch.sh`).

## 7. Verifica

- Ogni regola qui sopra che si può provare senza schermo ha un test in CI (logica di disegno e
  agganci, shader compilati, puntatore). Ciò che si vede solo a schermo va in `docs/DA_PROVARE.md`
  per la prova di Ross, con i passi esatti.
