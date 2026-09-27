# Confronto delle revisioni di libreria

27/09/2026 · T106 · Contratto del motore per l'integrazione T97 di Claude.

Prima di confermare l'importazione, il motore restituisce le definizioni native
prima/dopo, le differenze per ID di pin/piazzole/grafica e i componenti che usano
la revisione confrontata. Una nuova revisione si aggiunge alla libreria: i
componenti già posati mantengono quella precedente. Il confronto non autorizza
una sostituzione e non certifica l'equivalenza elettrica o meccanica.

## API e ciclo dell'anteprima

```swift
let command = ElectronicsLibraryCommand.importLibrary(importResult)
let preview = try ElectronicsLibraryCommands.preview(
    command, document: document, expectedRevision: document.revision
)
// preview.revisionDiffs: mostrare prima/dopo, campi e componenti interessati.
// Annulla/Esc: scartare command e preview, senza cambiare il documento.
// Conferma: lo stesso command con la revisione conservata nell'anteprima.
try ElectronicsLibraryCommands.apply(
    command, to: &document, expectedRevision: preview.baseRevision
)
```

`LibraryCommandPreview` è ora `Codable`, `Equatable` e `Sendable`. Oltre ai campi
esistenti `baseRevision`, `library` e `issues`, espone
`revisionDiffs: [LibraryRevisionDiff]`. Anche `.createDevice` usa lo stesso percorso.

Per un confronto senza un comando:

```swift
let diffs = try ElectronicsLibraryComparison.compare(
    current: document.design, proposedLibrary: proposedLibrary
)
```

La proposta deve contenere tutte le revisioni esistenti, immutate, e le nuove.
Rimozione o modifica di una revisione esistente produce
`library_revision_conflict` con l'ID della definizione. Identità duplicate o
riferimenti invalidi producono la normale diagnostica d'integrità. Nessuna
mutazione, I/O, rete, lettura dell'orologio o dipendenza UI nel confronto.

## Contenuto del risultato

| Dato | Significato |
|---|---|
| `before: LibraryDefinition?` | Definizione esistente; `nil` solo per una nuova famiglia UUID/tipo. |
| `after: LibraryDefinition` | Nuova definizione nativa completa: simbolo, impronta o dispositivo. |
| `changedFields` | Campi cambiati: geometria, metadati/provenienza, centro di presa, riferimento 3D, pin-map, fornitore e riferimenti del dispositivo. |
| `pins`, `pads`, `graphics` | `LibraryEntityChange<T>` con UUID, valori prima/dopo e tipo aggiunta/rimozione/modifica. Le quote sono quelle native in mm. |
| `affectedComponentIDs` | Componenti del progetto agganciati **esattamente a `before.key`**, direttamente al dispositivo o tramite il suo simbolo/impronta. Sono componenti da valutare, non modificati dall'importazione. |
| `isOlderRevision` | La revisione proposta ha un numero inferiore a quella confrontata. Il confronto è esplicito e nessun componente viene retrocesso. |

Se esistono revisioni 1 e 2 e si importa la 3, il motore genera due confronti:
1→3 con i componenti della 1 e 2→3 con quelli della 2. Anche una revisione non
usata viene confrontata, con elenco componenti vuoto. Nuove definizioni dello
stesso bundle si confrontano con la libreria iniziale, non fra loro.

I risultati sono ordinati per tipo, UUID, nuova revisione e revisione precedente;
entità e componenti sono ordinati per UUID. L'ordine degli array di pin, piazzole,
grafica e pin-map non determina una differenza. I valori prima/dopo conservano
però l'ordine originale: non si promette identità byte per byte di JSON ottenuti
da sorgenti riordinati. Lo stesso UUID di pin/piazzola con numero o geometria
diversi è una modifica; stesso numero con UUID diverso è rimozione + aggiunta.

Una revisione nuova dal contenuto identico genera comunque un confronto con
`changedFields` vuoto. Il reimport della stessa chiave identica non genera
confronti né passi di undo. Restano i limiti degli ID legacy descritti in
[LIBRARIES.md](LIBRARIES.md): il motore non indovina corrispondenze semantiche.

## Integrazione richiesta a Claude

Nel pannello d'importazione mostrare nuova definizione o coppia di revisioni,
campi cambiati, conteggi e dettagli delle entità, riferimenti dei componenti da
valutare. Usare i valori nativi per il disegno prima/dopo e gli ID forniti per
identificare i componenti; non rifare il confronto nell'app. I colori e la
presentazione appartengono alla UI. Segnalare le revisioni precedenti importate.

Eseguire il lavoro fuori dal MainActor; associare il risultato all'identità del
documento, epoca di apertura e revisione. Annullamento, riapertura o nuovo import
invalidano il worker. Il motore controlla la cancellazione nei cicli principali;
non c'è ancora un benchmark su cataloghi di grandi dimensioni. Confermare con
lo stesso comando e `baseRevision`; documento cambiato → anteprima obsoleta.

L'importazione è una sola transazione annullabile, anche dopo salvataggio e
riapertura; non cambia componenti, connessioni, schema o rame già presenti.
Formato documento 7 invariato. Il report è un'anteprima, non una nuova voce
persistente obbligatoria nel documento.

## CLI e prove

```text
electronics-library preview-import documento.json bundle.json revisioneAttesa anteprima.json
electronics-library apply-import documento.json bundle.json revisioneAttesa nuovo-documento.json
```

La CLI non sovrascrive output e lascia invariato il documento di input. Il JSON
segue la sintesi `Codable` di Swift: le enum delle definizioni usano per esempio
`footprint._0`. Le proprietà calcolate `kind` e `isOlderRevision` si ricavano dai
valori, non sono campi JSON separati. Nessuna promessa di formato di scambio
esterno versionato per questo report di anteprima.

Eseguire `bash scripts/test-electronics.sh`: `LibraryComparisonTests` copre
geometria, identità, pin-map, componenti di revisioni diverse, metadati, errori,
anteprima e storico. Il lettore Python controlla separatamente un'importazione
KiCad revisionata: piazzole spostate da ±0,825 a ±0,925 mm, UUID, input immutato,
stato dopo conferma e rifiuto di revisioni obsolete/output esistenti.
Risultati e limiti della prova UI in [VALIDATION.md](VALIDATION.md).
