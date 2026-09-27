# Circuiti — contratto chat e MCP v1

T100 (aggancio Claude), T104 (collaudo Codex). Gli strumenti operano sul circuito
aperto nell'app, attraverso gli stessi `ElectronicsCommand` della UI. Unità mm,
scheda vista dall'alto, rotazioni positive antiorarie. Nessuna libreria runtime esterna.
Le prove effettivamente eseguite sono in [VALIDATION.md](VALIDATION.md).

## Catalogo

| Strumento | Risultato |
|---|---|
| `circuit_info` | Identità, revisione, scheda, componenti, reti, rame, varianti e stato del controllo DRC. |
| `circuit_issues` | Diagnostica con codici, ID dei soggetti e posizione. Se il DRC non è pronto lo dichiara. |
| `circuit_library` | Dispositivi disponibili, chiavi di libreria, prefissi, valori e pin. |
| `circuit_pins` | Pin di un componente, rete e marcatura NC. |
| `circuit_fabrication_check` | Preflight, nove strati, fori, errori e possibilità di export; non scrive file. |
| `circuit_preview` | Comando calcolato su una copia, ID di anteprima e problemi; documento invariato. |
| `circuit_apply` | Applica esattamente il comando dell'anteprima alla revisione prevista. |
| `circuit_undo` / `circuit_redo` | Annulla/ripete solo una voce dello storico appartenente all'assistente. |

Azioni di `circuit_preview`:

- `add_component`, `move_component`, `rotate_component`, `flip_component`, `remove_component`;
- `connect`, `disconnect`, `no_connect`, `rename_net`;
- `set_board` (rettangolo), `add_track`, `add_via`, `remove_copper`.

Nomi e parametri completi sono nello schema restituito da `tools/list`. Usare le
chiavi di `circuit_library` e i nomi `R1.2` di `circuit_pins`, senza inventare pinout
o codici commerciali. I modelli generici richiedono verifica rispetto al pezzo reale.

## Transazione e storico

1. Leggere `circuit_info` e conservare `revision`.
2. Chiamare `circuit_preview` con azione, parametri ed `expected_revision`.
3. Esaminare `can_apply`, `blocking_issues` e `new_issues`; nulla è ancora cambiato.
4. Chiamare `circuit_apply` con `preview_id` ed `expected_revision` della stessa
   anteprima. Una modifica effettiva crea un passo; un no-op restituisce `changed:false`.
5. Per il comando seguente usare il nuovo `revision` restituito.

Il token distingue identità del circuito, apertura del file e revisione monotona.
Riaprire un file con identità e numero di revisione uguali invalida comunque le
anteprime. Anche Annulla/Ripeti avanzano la revisione. Il token CAD non vale per
Circuiti: il router sceglie il modello in base al nome dello strumento.

La proprietà di una voce Annulla riguarda questa sessione, non è un nuovo campo
nel formato documento. L'assistente si ferma davanti a un passo manuale. Un nuovo
ramo dello storico invalida le vecchie voci, anche quando l'utente ricrea esattamente
la stessa geometria. Un no-op non attribuisce all'assistente il passo precedente.

I tipi errati e i parametri sconosciuti sono rifiutati. Il DRC applica la stessa
politica della UI: gli errori sul rame nuovo/modificato bloccano; spostamenti di
componenti e riparazioni possono mantenere diagnostica. Il preflight di produzione
richiede invece che gli errori produttivi siano risolti.

## Produzione e limiti

`circuit_fabrication_check` accetta variante, espansione maschera, riduzione pasta
e copertura via. L'export con scelta della cartella si esegue in **Circuiti →
Produzione → Gerber**: [FABRICATION.md](FABRICATION.md). Il controllo dalla chat
non equivale a un pacchetto già scritto su disco.

Questa versione aggiunge componenti sul PCB e connessioni logiche. Non espone
ancora tutti i comandi dello schema grafico, piani/termiche, regole avanzate,
importazione librerie o assiemi 3D. T98 resta aperto per la parità completa UI/MCP
e l'accettazione su una scheda reale. L'esecuzione locale del protocollo prova il
bridge e l'app; le chiamate ai singoli provider AI hanno evidenze separate.

## Apple Intelligence locale

Nel contesto piccolo, il provider presenta strumenti specifici per rinominare reti,
aggiungere/spostare/ruotare/eliminare componenti, collegare/scollegare pin e NC.
Sono adattatori dei campi di `circuit_preview`: producono la stessa anteprima,
seguita da `circuit_apply`, senza una seconda logica elettronica. Letture, preflight,
Annulla e Ripeti restano disponibili. Piste, via, lato, dimensioni della scheda e
rimozione rame restano nel catalogo completo MCP/provider remoto, ma non in questo
sottoinsieme del modello locale.

Il contesto segue la scheda CAD/Circuiti e rigenera la sessione quando cambia il
catalogo. Le risposte compatte conservano sempre ID di anteprima, revisione ed
esito; le liste diagnostiche vengono ridotte. La prova dal vivo ha verificato
rinomina di una rete con Annulla e collegamento di due pin, non l'affidabilità del
modello su qualunque progetto o richiesta.
