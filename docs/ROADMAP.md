# Roadmap — un passo alla volta

Regola (Ross, 25/09): **si procede un passo alla volta, con calma**. Si lavora solo sul
passo *In corso*; il passo successivo parte quando Ross ha visto il risultato e lo approva.
Nuove idee o richieste si aggiungono in fondo a *Da valutare*, non si iniziano subito.
I task tecnici di dettaglio restano nel grafo (`docs/graph`), ma l'ordine lo decide questa pagina.

Stato: **approvata da Ross il 25/09**. Aggiornamento comunicato da Claude nel
registro: Ross proverà il passo 1 più tardi e ha chiesto di avanzare al passo 2.

| # | Passo | Cosa vede Ross alla fine | Chi | Stato |
|---|---|---|---|---|
| 1 | **Consolidare quello che c'è** — chat provata dal vivo con le chiavi di Ross, Claude Desktop collegato, colori delle parti + export 3MF nell'interfaccia, test automatici che girano con un comando | Chiede all'assistente "fai una staffa", la vede comparire, la colora, la esporta in 3MF e la apre nello slicer | Claude (UX) + Codex (test/CI) | **In attesa delle prove di Ross; CI T13 da completare** |
| 2 | **Motore geometrico nostro (base)** — solidi B-rep a facce piane con identità stabili di facce e spigoli | Nessuna novità visibile grossa, ma si possono selezionare facce e spigoli nel viewport | Codex (motore) + Claude (selezione) | **In corso: UX T72; kernel T70 da iniziare** |
| 3 | **Storico vero** — ogni operazione nella timeline si modifica, si elimina, si sopprime, marker di rollback, salvataggio | Cambia un valore di un'operazione di prima e tutto il pezzo si aggiorna | Codex + Claude | — |
| 4 | **Schizzo salvato, su piani e su facce** | Clicca una faccia, disegna, estrude; modifica lo schizzo dalla timeline | Codex + Claude | — |
| 5 | **Operazioni sui solidi, una per volta**: Estrudi con Unisci/Taglia/Interseca → Smusso → Raccordo → Specchio → Dividi con piano → piani di costruzione | Ogni operazione arriva completa (pannello, anteprima, storico) prima della successiva | Codex + Claude | — |
| 6 | **Assistente che usa tutto quanto sopra** (strumenti v2) | L'assistente sa fare schizzi su facce, tagli, smussi e correggere lo storico | Codex + Claude | — |
| 7 | **Parti e assiemi** | — | — | — |
| 8 | **Lamiera** | — | — | — |
| 9 | **Prima release TestFlight ai colleghi** | — | Ross + Claude | — |

## Da valutare (non iniziati)

- Spigoli di selezione più spessi nel viewport (linee larghe via quad in Metal).

## Decisioni già prese

- Mac, Xcode, SwiftUI; viewport Metal.
- Claude = UX, Codex = funzionalità; accordi nel registro `docs/COLLAB.md`.
- Chiavi API: ognuno usa la propria (Anthropic / OpenAI), salvata nel Portachiavi.
- Distribuzione ai colleghi via TestFlight; connettore Claude Desktop incluso nell'app.
- Motore geometrico e funzioni **nostri**; OpenCascade escluso dal piano.
  Librerie esterne solo se strettamente necessarie, con motivazione concreta
  concordata con Ross: [regole sulle dipendenze](requirements/DEPENDENCY_POLICY.md).
- Export per la stampa: STL e 3MF con colori (Bambu Studio, OrcaSlicer, Snapmaker Orca).
