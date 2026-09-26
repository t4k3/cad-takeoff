# Roadmap — un passo alla volta

Regola (Ross, 25/09): **si procede un passo alla volta, con calma**. Si lavora solo sul
passo *In corso*; il passo successivo parte quando Ross ha visto il risultato e lo approva.
Nuove idee o richieste si aggiungono in fondo a *Da valutare*, non si iniziano subito.
I task tecnici di dettaglio restano nel grafo (`docs/graph`), ma l'ordine lo decide questa pagina.

Stato: **approvata da Ross il 25/09**. Aggiornamento comunicato da Claude nel
registro: Ross proverà il passo 1 più tardi e ha chiesto di avanzare al passo 2.

Aggiornamento diretto Ross a Codex, 25/09: «comincia lamiere, vedi cosa fa Fusion
e poi fai la base». Autorizzata l’anticipazione della sola base motore lamiera
T78, senza chiudere la copertura completa o alterare il lavoro schizzo di Claude.

## Fondamenta (dall'analisi del 26/09, prima di proseguire con i passi)

| Fase | Cosa | Stato |
|---|---|---|
| 0 | Annulla/Ripeti veri per ogni modifica + avviso alla chiusura | **Fatta** — in attesa di prova di Ross |
| 1 | Documento v2 unico con storico (solidi, schizzi, lamiera) + migrazione file | **Fatta** — timeline, marker, soppressione; lamiera nel formato ma non ancora disegnata (T79) |
| 2 | Vista 3D e selezione sul motore B-rep | **Fatta** — ID stabili di facce/spigoli, normali lisce, diagnosi geometrie non valide |
| 3 | Booleane: Unisci / Taglia / Interseca | **Fatta** — motore CSG nostro, risultati chiusi, facce con identità, export uniti |
| 3b | **Foro** (richiesta Ross 26/09): semplice, lamato, svasato; viti M2–M12 per passaggio, filettatura indicata (preforo per maschio) o inserto a caldo; passante o cieco; più fori su faccia piana | **Fatta** — in attesa di prova di Ross. Posizione con aganci (vertici, punti medi, centri di cerchi e facce, punti dello schizzo proiettati) e coordinate X/Y/Z scritte a mano (richiesta Ross 26/09). Filetto *modellato* rinviato (serve motore booleane più veloce) |
| 3c | **Smusso** (chamfer, richiesta Ross 26/09): distanza uguale / due distanze / distanza+angolo, su spigoli selezionati | **Fatta** — in attesa di prova di Ross. Spigoli dritti tra facce piane e bordi circolari (cilindri, bocca dei fori); spigoli concavi, archi parziali e anteprima di un nuovo smusso non ancora |
| 3d | **Raccordo** (fillet, richiesta Ross 26/09): raggio costante su spigoli selezionati, tangenza automatica | **Fatta** — in attesa di prova di Ross. Un solo comando «Raccordo» con forma Tondo o Piatto (lo smusso), come chiesto da Ross il 26/09; spigoli dritti e bordi di cilindri/fori (superficie toroidale). Freccia da trascinare sullo spigolo e anteprima dal vivo (anche per un nuovo smusso). Angoli tra più raccordi: incrocio semplice, non ancora il raccordo sferico d'angolo di Fusion |

| # | Passo | Cosa vede Ross alla fine | Chi | Stato |
|---|---|---|---|---|
| 1 | **Consolidare quello che c'è** — chat provata dal vivo con le chiavi di Ross, Claude Desktop collegato, colori delle parti + export 3MF nell'interfaccia, test automatici che girano con un comando | Chiede all'assistente "fai una staffa", la vede comparire, la colora, la esporta in 3MF e la apre nello slicer | Claude (UX) + Codex (test/CI) | **In attesa delle prove di Ross; CI T13 completata** |
| 2 | **Motore geometrico nostro (base)** — solidi B-rep a facce piane con identità stabili di facce e spigoli | Nessuna novità visibile grossa, ma si possono selezionare facce e spigoli nel viewport | Codex (motore) + Claude (selezione) | **In corso: prima base verificata (T75), primitive e snapshot; integrazione UX da fare** |
| 3 | **Storico vero** — ogni operazione nella timeline si modifica, si elimina, si sopprime, marker di rollback, salvataggio | Cambia un valore di un'operazione di prima e tutto il pezzo si aggiorna | Codex + Claude | — |
| 4 | **Schizzo salvato, su piani e su facce** | Clicca una faccia, disegna, estrude; modifica lo schizzo dalla timeline | Claude | **Fatto 26/09** (prova a schermo da completare: schermo bloccato): «Schizzo» → clic su faccia piana o Piano XY, camera di fronte, spigoli della faccia proiettati (tratteggio arancione, aggancio), Estrudi fuori dalla faccia o dentro il pezzo (i tagli vanno dentro), assistente con face_point/face_normal |
| 5 | **Operazioni sui solidi, una per volta**: Estrudi con Unisci/Taglia/Interseca → Smusso → Raccordo → Specchio → Dividi con piano → piani di costruzione | Ogni operazione arriva completa (pannello, anteprima, storico) prima della successiva | Codex + Claude | — |
| 6 | **Assistente che usa tutto quanto sopra** (strumenti v2) | L'assistente sa fare schizzi su facce, tagli, smussi e correggere lo storico | Codex + Claude | — |
| 7 | **Parti e assiemi** | Inserire i pezzi del progetto in un assieme, posizionarli, distinta base | Claude | **Fase 1 fatta 26/09**: componenti collegati ai file (si aggiornano), posizione e rotazione, Apri pezzo, distinta base con CSV. Poi: giunti/vincoli di accoppiamento, interferenze, componente attivo, esplosi |
| 8 | **Lamiera** | Campione piegato + sviluppo DXF/3MF e operazioni salvate | Claude | **Base integrata (26/09): scheda LAMIERA, materiali con regole da pressa piegatrice (V, raggio, K DIN 6935, flangia minima), piastra + flange sui 4 lati, sviluppo, DXF, assistente.** Poi: altezze per lato nel pannello, fori riportati nello sviluppo/DXF. Prossimo: angoli chiusi, flange su flange. [Dettagli](requirements/SHEET_METAL_V1.md) |
| 9 | **Prima release TestFlight ai colleghi** | I colleghi installano da TestFlight e usano la propria chiave | Ross + Claude | **Preparata 26/09**: icona, privacy manifest, crittografia esente, build Release, `scripts/archive-testflight.sh`. **Tocca a Ross**: account in Xcode, app in App Store Connect, primo caricamento → [guida](TESTFLIGHT.md) |

## Da valutare (non iniziati)

- Lamiera: angoli chiusi con scarico, flange su flange (Z, cassette), orli, fori che attraversano una piega o asole nello sviluppo, tavola di piega.

- Smusso/raccordo su spigoli **concavi** (aggiunge materiale) e su **archi** parziali; angolo sferico dove si incontrano tre raccordi.
- Freccia di trascinamento anche per Estrudi, Foro (profondità) e parametri dei solidi.
- Booleane più veloci: la mesh finale ora è unita per faccia (−50/−55% triangoli, 26/09), ma l'albero BSP lavora ancora sui frammenti; servono un BSP con poligoni convessi uniti o un motore diverso (anche per il filetto modellato).

- Spigoli di selezione più spessi nel viewport (linee larghe via quad in Metal).
- **Home / gestione progetti (idea di Ross, 25/09)** — come il pannello Dati di Fusion, ma **in locale**:
  una dashboard iniziale con *Progetti → cartelle → disegni* (parti, assiemi), miniature, data e versioni,
  per creare, aprire, rinominare, spostare e cercare i disegni e tenere ordinato un progetto intero.
  È la base naturale per gli assiemi (riferimenti tra file dello stesso progetto).
  Chi: Codex (struttura su disco, indice, versioni, riferimenti tra file) + Claude (dashboard, anteprime, navigazione).
- **Import da Fusion 360 (T74) — fase 1 fatta 26/09**: import STL/OBJ/3MF come corpi con facce piane vere (selezione, fori, schizzi);
  add-in per Fusion «Esporta per Fusion Takeoff» (un clic o a ogni salvataggio, scrive il .ftk nella cartella del progetto: corpi e
  componenti già posizionati, colori, mm, Y-su → Z-su), installabile dalla Home. Collaudato con un'API Fusion simulata; **da provare
  nel vero Fusion con Ross**. Fase 2: storico parametrico (schizzi, estrusioni, fori) invece delle sole mesh.

## Decisioni già prese

- Mac, Xcode, SwiftUI; viewport Metal.
- Claude = UX, Codex = funzionalità; accordi nel registro `docs/COLLAB.md`.
- Chiavi API: ognuno usa la propria (Anthropic / OpenAI), salvata nel Portachiavi.
- Distribuzione ai colleghi via TestFlight; connettore Claude Desktop incluso nell'app.
- Motore geometrico e funzioni **nostri**; OpenCascade escluso dal piano.
  Librerie esterne solo se strettamente necessarie, con motivazione concreta
  concordata con Ross: [regole sulle dipendenze](requirements/DEPENDENCY_POLICY.md).
- Export per la stampa: STL e 3MF con colori (Bambu Studio, OrcaSlicer, Snapmaker Orca).
