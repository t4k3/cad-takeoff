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
