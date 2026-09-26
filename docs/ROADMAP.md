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
| 3d | **Raccordo** (fillet, richiesta Ross 26/09): raggio costante su spigoli selezionati, tangenza automatica | prossima |

| # | Passo | Cosa vede Ross alla fine | Chi | Stato |
|---|---|---|---|---|
| 1 | **Consolidare quello che c'è** — chat provata dal vivo con le chiavi di Ross, Claude Desktop collegato, colori delle parti + export 3MF nell'interfaccia, test automatici che girano con un comando | Chiede all'assistente "fai una staffa", la vede comparire, la colora, la esporta in 3MF e la apre nello slicer | Claude (UX) + Codex (test/CI) | **In attesa delle prove di Ross; CI T13 completata** |
| 2 | **Motore geometrico nostro (base)** — solidi B-rep a facce piane con identità stabili di facce e spigoli | Nessuna novità visibile grossa, ma si possono selezionare facce e spigoli nel viewport | Codex (motore) + Claude (selezione) | **In corso: prima base verificata (T75), primitive e snapshot; integrazione UX da fare** |
| 3 | **Storico vero** — ogni operazione nella timeline si modifica, si elimina, si sopprime, marker di rollback, salvataggio | Cambia un valore di un'operazione di prima e tutto il pezzo si aggiorna | Codex + Claude | — |
| 4 | **Schizzo salvato, su piani e su facce** | Clicca una faccia, disegna, estrude; modifica lo schizzo dalla timeline | Codex + Claude | — |
| 5 | **Operazioni sui solidi, una per volta**: Estrudi con Unisci/Taglia/Interseca → Smusso → Raccordo → Specchio → Dividi con piano → piani di costruzione | Ogni operazione arriva completa (pannello, anteprima, storico) prima della successiva | Codex + Claude | — |
| 6 | **Assistente che usa tutto quanto sopra** (strumenti v2) | L'assistente sa fare schizzi su facce, tagli, smussi e correggere lo storico | Codex + Claude | — |
| 7 | **Parti e assiemi** | — | — | — |
| 8 | **Lamiera** | Campione piegato + sviluppo DXF/3MF e operazioni salvate | Codex (motore) + Claude (UX) | **Base core T78 verificata: regole, rettangolo, singola flangia, sviluppo. Integrazione app/chat e funzioni avanzate da fare.** [Contratto](requirements/SHEET_METAL_V1.md) |
| 9 | **Prima release TestFlight ai colleghi** | — | Ross + Claude | — |

## Da valutare (non iniziati)

- Smusso su spigoli **concavi** (aggiunge materiale) e su **archi** parziali; anteprima dal vivo anche per un nuovo smusso.
- **Semplificare la mesh dopo le booleane** (unire i frammenti complanari della stessa faccia): oggi un foro + smusso su una piastra
  produce ~16.000 triangoli; serve prima del raccordo e del filetto modellato per restare veloci.

- Spigoli di selezione più spessi nel viewport (linee larghe via quad in Metal).
- **Home / gestione progetti (idea di Ross, 25/09)** — come il pannello Dati di Fusion, ma **in locale**:
  una dashboard iniziale con *Progetti → cartelle → disegni* (parti, assiemi), miniature, data e versioni,
  per creare, aprire, rinominare, spostare e cercare i disegni e tenere ordinato un progetto intero.
  È la base naturale per gli assiemi (riferimenti tra file dello stesso progetto).
  Chi: Codex (struttura su disco, indice, versioni, riferimenti tra file) + Claude (dashboard, anteprime, navigazione).
- **Import automatico da Fusion 360 (idea di Ross, 25/09)** — ➜ **affidato a Claude da Ross (T74), dopo la Home (T73).** collegata alla Home. Note tecniche:
  il formato `.f3d/.f3z` è chiuso e non documentato, quindi leggerlo direttamente non è affidabile.
  Strade possibili, dalla più semplice alla più completa:
  1. import di mesh (STL/3MF/OBJ esportati da Fusion): subito fattibile, ma senza storico;
  2. **add-in "Esporta per Fusion Takeoff" dentro Fusion** (API ufficiale di Fusion, Fusion è installato su questo Mac):
     legge timeline, schizzi e parametri e scrive il nostro formato, anche in automatico su una cartella del progetto
     → import *con storico*, limitato alle operazioni che il nostro motore supporta;
  3. import STEP: richiede di convertire superfici NURBS nel nostro motore, lavoro pesante.
  Da decidere con Ross: dove metterla nell'ordine (proposta: Home dopo il passo 4, import via add-in insieme al passo 7 parti e assiemi).

## Decisioni già prese

- Mac, Xcode, SwiftUI; viewport Metal.
- Claude = UX, Codex = funzionalità; accordi nel registro `docs/COLLAB.md`.
- Chiavi API: ognuno usa la propria (Anthropic / OpenAI), salvata nel Portachiavi.
- Distribuzione ai colleghi via TestFlight; connettore Claude Desktop incluso nell'app.
- Motore geometrico e funzioni **nostri**; OpenCascade escluso dal piano.
  Librerie esterne solo se strettamente necessarie, con motivazione concreta
  concordata con Ross: [regole sulle dipendenze](requirements/DEPENDENCY_POLICY.md).
- Export per la stampa: STL e 3MF con colori (Bambu Studio, OrcaSlicer, Snapmaker Orca).
