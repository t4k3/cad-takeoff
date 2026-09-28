# Collaudo dell'importazione nell'app — T108

Usare una copia Debug dedicata, senza modificare i progetti aperti da Ross.
Sorgenti reali in Downloads: Ballgunmain_hw.zip, bom.csv, positions.csv.
Salvare solo nuovi documenti QA in build/electronics/acceptance-108.

## Criteri

1. CIRCUITI → PRODUZIONE → Importa, scegliere insieme ZIP/BOM/CPL in qualsiasi
   ordine. Prima della conferma: 65×81mm,9strati,158forature,84/86montati,
   IC2/T1esclusi e J8senzaLCSC; scheda disegnata, limiti dello schema/3D dichiarati.
2. Annulla lascia documento e storico invariati. Ripetere e confermare:
   esattamente un passo di annulla, geometria e componenti visibili.
3. Nella tabella verificare T1 sul lato inferiore escluso; IC2 senza posizione
   non riceve un centro inventato. Nascondere/mostrare strati e fori.
4. Creare un lotto Prototipi, cambiare Monta per un componente, tornare al lotto
   originale: il suo montaggio resta invariato e la geometria non cambia.
5. Salva; annulla/ripeti una modifica; salva e riapri. Lotti, selezione del lotto,
   montaggio e storico sono conservati. I file originali restano identici.
6. Reimportare con nome di lotto diverso aggiunge un lotto sullo stesso pacchetto;
   una sostituzione di parte nota è rifiutata con spiegazione, senza alterare lotti.
7. Assistente/MCP: lettura CAM dichiarata, lotti/componenti recuperabili; variazioni
   passano da preview/apply/revisione e undo. Nessun esito DRC/ERC nativo "pulito"
   su artwork importato. Nessun ordine o caricamento verso JLCPCB.

## Prove automatiche complementari

Il motore verifica ZIP/Gerber/Excellon/CSV e storico. Il ponte app deve coprire
letture sospese e annullamento/riapertura, proposta obsoleta, documenti diversi,
reimport con componenti/posizioni aggiunti e aggiornamento dell'indice.
Un test asincrono cattura il task originario prima dell'invalidazione e attende
quel task dopo il rilascio del gate, senza affidarsi a un handle azzerato.

Risultati effettivi, build e limiti osservati vanno in VALIDATION.md. Questo file
è la procedura, non un'attestazione che ogni passaggio sia già riuscito.

## Regressione del primo disegno — T110

Il 28/09 Ross ha segnalato una vista inizialmente composta solo da cerchietti;
circa un minuto dopo è comparso l'artwork. Nella build qa-t108b delle 15:06 sono
stati osservati prima i soli marcatori dei componenti, poi rame, serigrafia e
contorno. La precedente verifica dei comandi degli strati non dimostrava il
tempo necessario per il primo disegno: questa parte del collaudo è riaperta.

Ripetere l'importazione in una build dedicata, con cache inizialmente vuota:

1. Misurare separatamente lettura/importazione, preparazione grafica e primo
   disegno completo. Non fermare il cronometro alla comparsa dei marcatori.
2. Verificare che il primo disegno arrivi senza hover, zoom, cambio scheda o
   ridimensionamento; l'aggiornamento dello stato deve invalidare il renderer.
3. Durante la preparazione mostrare uno stato di caricamento. Menu e annullamento
   devono restare utilizzabili; nessun lavoro lungo sul thread della UI.
4. Alternare rame superiore/inferiore, serigrafia e fori; zoomare e tornare ad
   Adatta. Verificare contenuto e risposta, non soltanto lo stato dei pulsanti.
5. Verificare una seconda apertura dello stesso circuito e il passaggio a un
   altro documento durante la preparazione: nessun risultato tardivo del primo.
6. Conservare polarità locali delle aperture e dei singoli strati. Un renderer
   più veloce che cancella o fonde geometria diversa non supera il collaudo.

Misure motore del 28/09, prima di modifiche App: tre esecuzioni Debug della CLI
con i tre originali, inclusa serializzazione e scrittura, in 0,443/0,434/0,439 s.
Ogni documento contiene 9 strati e 5.715 primitive. Il test reale con 100 cambi
lotto, undo e riapertura passa in 3,949 s; costruzione dell'indice picking 323 ms,
query pick+snap p95 2,98 ms. Queste misure non attestano la velocità della UI.
Evidenza locale: `build/electronics/acceptance-110/core-timings.json` e
`/tmp/ftk-t110-real-core.log`.

### Esito della correzione, 28/09/2026

Causa isolata nell'app: `drawing` e gli stati degli strati erano letti soltanto
nella closure di `Canvas`, senza creare la dipendenza del body della vista.
Il disegno era pronto ma non provocava l'aggiornamento. Claude ha portato le
letture nel body, aggiunto lo stato «Preparo gli strati…» e un test a pixel sulla
vista reale. Il confronto precedente/corretto, registrato in COLLAB alle 15:41,
fallisce con la vista precedente e passa con la nuova (primo artwork in 135 ms
nel banco, senza mouse o zoom). Correzione App nel commit `0364bb8`.

Verifica indipendente Codex:

- `FTK_MANUFACTURING_FIXTURE_DIR=/Users/ross/Downloads bash scripts/test-circuits.sh`
  PASS, exit 0, inclusi primo frame e spegnimento di uno strato; log
  `/tmp/ftk-t110-app-independent.log`.
- `swift test --package-path Packages/CADCore`: 202 test PASS; log
  `/tmp/ftk-t110-cad.log`.
- QA nativa nella build separata `build/qa-t110/FusionTakeoff.app`, compilata
  alle 15:41, v1.0.99: import dei tre originali da Downloads. Anteprima con
  artwork già visibile al primo screenshot; dopo conferma, rame, serigrafia e
  contorno già presenti al primo screenshot senza altre interazioni. Il tempo
  complessivo click/lettura accessibilità/screenshot è 1,779 s: limite superiore
  che include l'automazione, non misura del solo renderer.
- Rame inferiore spento: le piste blu scompaiono al primo screenshot successivo;
  riattivato prima di riaprire il file salvato da Ross.
- `Downloads/ballgunCANBUS.ftkc` riaperto nella build corretta: artwork completo,
  84/86 montati e nome/percorso corretto nella barra. Nessuna scrittura sul file.
  Scartato soltanto l'import temporaneo di questa prova, ricreabile dai sorgenti.
  Istanza precedente qa-t108b e lavoro dell'utente non chiusi o modificati.

Il motore e le API non hanno richiesto modifiche. La CI integrata di Claude è
una verifica separata e il suo esito va registrato dal log finale.
