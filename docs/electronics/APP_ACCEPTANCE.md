# Produzione e assistente Circuiti — T104

Collaudo circoscritto dell'integrazione T103/T100. Non chiude la qualificazione dei
componenti, JLCPCB, il multistrato o l'assieme 3D previsti in T92–T98.

## Preparazione

```sh
python3 Tests/Electronics/prepare_fabrication_acceptance.py build/electronics/acceptance-104
```

Lo script rifiuta directory esistenti e crea copie della fixture sintetica T103:

- `01-produzione.ftkc`: scheda 40 × 30 mm, J1/R1/D1, quattro piste e un via;
  variante «Senza D1», origine di assemblaggio (10, 5). Nessun componente qualificato.
- `02-pista-mancante.ftkc`: prima pista rimossa; preflight ed export devono fermarsi.
- `03-stessa-identita-dnp.ftkc`: identità e revisione della prima, file diverso e D1
  non montato. Verifica che la riapertura invalidi le elaborazioni precedenti.
- `acceptance.json`: identità di riferimento, revisione e conteggi attesi.

Usare la copia Debug dell'app e queste copie; nessuna prova modifica progetti reali.

## Criteri verificabili

1. Aprire Circuiti → Produzione: nove strati e tre fori, rapporto con avvisi
   selezionabili e zero errori sulla prima fixture. Il lato inferiore conserva la
   vista dall'alto, coerente con l'anteprima del motore.
2. Esportare in una cartella nuova: 17 file, stessa identità/revisione/profilo/variante
   del rapporto; nessun passo Annulla. Una destinazione occupata resta invariata.
3. Cambiare maschera/pasta e copertura via: l'anteprima si aggiorna; i file esportati
   devono rispettare il profilo selezionato. Valori non validi impediscono l'export.
4. «Senza D1»: niente pasta sul lato inferiore, rame/maschera/fori invariati. Nessun
   cambio geometrico o passo Annulla. La terza fixture verifica anche il DNP persistito.
5. Sulla seconda fixture: errore con soggetti identificabili, nessuna cartella
   parziale e nessun export riuscito. Tornare alla prima non conserva l'errore vecchio.
6. Chat e MCP vedono strumenti Circuiti e identità/revisione correnti. Anteprima di
   un comando → nessuna modifica; conferma dello stesso comando → un solo passo;
   Annulla/Ripeti ripristinano i dati e avanzano la revisione.
7. Una conferma vecchia, un comando bloccato dal DRC, dati malformati o un'altra
   apertura non modificano il circuito. Si deve ottenere un errore comprensibile.
8. L'assistente è accessibile da Circuiti. Il contratto strumenti è lo stesso per
   chat interna e MCP; una prova HTTP locale non dimostra una chiamata al provider AI.

Per ogni export della fixture:

```sh
python3 Tests/Electronics/check_fabrication.py CARTELLA_EXPORT FILE_SORGENTE.ftkc
```

Il lettore indipendente controlla geometria, profilo, variante, forature, origine,
orientamento inferiore e hash. È dedicato alle fixture sintetiche manuali; non è
un parser Gerber generale. Le prove asincrone deterministiche dell'app spettano
a Claude in `Tests/Circuits`; quelle native e HTTP a Codex. Le evidenze effettive
sono registrate in `VALIDATION.md` dopo l'esecuzione, non dedotte da questi criteri.

## MCP locale

Aprire nell'app una copia fresca di `01-produzione.ftkc` (revisione zero), poi:

```sh
python3 Tests/Electronics/check_mcp_circuits.py FILE_DISCOVERY_MCP NUOVA_CARTELLA_EVIDENZE
```

`FILE_DISCOVERY_MCP` è il file `mcp.json` scritto dall'app nel suo App Group o
Application Support. Lo script accetta solo il server HTTP `127.0.0.1` dell'app,
legge il bearer in memoria e non lo stampa né lo copia nelle evidenze. Prima di
modificare controlla identità, nome e revisione della fixture; non salva il documento.

Se macOS protegge l'App Group dall'accesso del terminale, usare il bridge firmato
già incluso nell'app, lo stesso previsto per i client MCP; non cambiare i permessi:

```sh
python3 Tests/Electronics/check_mcp_circuits.py --bridge \
  build/qa-t100/FusionTakeoff.app/Contents/MacOS/ftk-mcp NUOVA_CARTELLA_EVIDENZE
```

In questa modalità Python non legge credenziali: parla JSON-RPC su stdio al bridge,
che inoltra le richieste al server HTTP locale dell'app con la propria autorizzazione.

Verifica catalogo e preflight, tipi degli argomenti, no-op, anteprima senza modifica,
conferma obsoleta rifiutata, due Annulla/Ripeti consecutivi, corto impedito, pista
valida, lettura della libreria e dei pin. Posa poi due resistenze temporanee,
collega una rete, marca un pin NC e ne scollega un altro; cinque annullamenti
ripristinano la geometria e la connettività iniziali. `calls.json` conserva le
richieste/risposte JSON-RPC e `summary.json` è scritto soltanto al PASS finale.
Lo storico in memoria contiene ancora passi di QA: riaprire la fixture scartando
esclusivamente queste modifiche temporanee. Non usare su un progetto reale.
