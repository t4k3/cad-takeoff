# Architettura condivisa — Fusion Takeoff

**Punto di ingresso per Codex e Claude.** L'obiettivo è un CAD essenziale per macOS,
sviluppato in Xcode, con disegno quotato, solidi e file per stampa 3D. La versione
attuale è un prototipo di modellazione a mesh; l'evoluzione parametrica è progressiva.

## Documenti autorevoli

| Documento | Funzione | Come si aggiorna |
|---|---|---|
| [COLLAB.md](../COLLAB.md) | Comunicazione progressiva tra gli agenti, decisioni, evidenze, problemi | Solo aggiunta in fondo, preferibilmente `scripts/graph.py log` |
| [Grafo delle attività](../graph/GRAPH.md) | Responsabili, dipendenze, stato e confini dei file | Solo attraverso `scripts/graph.py` |
| [Progetto e obiettivi](PROJECT.md) | Requisiti, fasi, criteri di accettazione | Revisione esplicita e nota nel registro |
| [Mappa navigabile](index.html) | Moduli, collegamenti e riferimenti al sorgente | Generata da `graph.json`, funziona offline |
| [Mappa Mermaid](MAP.md) | Stessa mappa, leggibile dagli agenti | Generata, non modificare a mano |
| [Rapporto di affidabilità](RELIABILITY.md) | Metodo, copertura e limiti delle evidenze | Aggiornare insieme alle sonde |

## Procedura ad ogni sessione

1. Leggere `AGENTS.md`, `graph.py status` e le ultime voci di `COLLAB.md`.
2. Reclamare un task disponibile; rispettarne i percorsi. Un suggerimento di
   assegnazione in roadmap non equivale a un claim né a un task completato.
3. Prima di usare la mappa eseguire `python3 scripts/architecture_graph.py check`.
4. Se è `STALE`, leggere i file cambiati, correggere nodi/archi in `graph-spec.json`
   e rigenerare. Il controllo degli hash prova l'allineamento dello snapshot,
   non la completezza semantica della mappa.
5. Eseguire test pertinenti, aggiungere esito e limiti al registro, quindi `done`
   oppure `handoff`. Una domanda al collega ha bisogno di risposta esplicita;
   la sola scrittura nel registro non prova che l'abbia letta.

```bash
python3 scripts/graph.py status
python3 scripts/graph.py next --agent codex  # oppure claude
python3 scripts/graph.py claim T02 codex    # esempio: scegliere un task realmente todo
python3 scripts/architecture_graph.py generate
python3 scripts/architecture_graph.py check
swift test --package-path Packages/CADCore
```

Gli agenti comunicano attraverso il repository condiviso. Il registro non li
risveglia e non invia notifiche automaticamente: va letto a inizio/fine task e
prima di modificare un contratto condiviso. Una comunicazione bloccante deve
indicare destinatario, task, domanda e criterio per riprendere.

## Formato di un passaggio di consegne

```text
Destinatario: Claude / Codex
Task e proprietario:
Obiettivo e criteri di accettazione:
File modificabili e contratti coinvolti:
Decisioni confermate / proposte ancora aperte:
Comandi eseguiti, esito e percorso delle prove:
Problemi residui:
Prossimo passo richiesto:
```

## Aggiornamento del grafo

`graph-spec.json` è la specifica curata a mano. `graph.json` è il dataset canonico
dello snapshot: conserva identità del checkout, hash, nodi, archi tipizzati,
target e riga di evidenza. HTML e Mermaid sono viste derivate.

Ogni nuovo file va inventariato; ogni nuovo confine runtime va dichiarato.
Il generatore segnala file senza simboli mappati. Non promuovere una relazione
testuale a `RESOLVED`: ciò richiede un successivo estrattore IndexStore/SourceKit.

Revisioni: 2026-09-25, v1, Codex, task T02. Le revisioni successive si registrano
in `COLLAB.md`, mantenendo distinguibili implementazione, build, UI e stampa reale.

