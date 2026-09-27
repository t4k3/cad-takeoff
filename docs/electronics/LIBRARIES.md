# Librerie componenti — prima consegna E1

27/09/2026 · T92 · Codex. Motore Swift nativo, Foundation e CryptoKit Apple; nessuna dipendenza software di terzi. I tre campioni KiCad sono **dati di componenti**, redistribuiti con fonte, hash, attribuzione e licenza in `Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/Library/`.

Questa consegna permette di importare, controllare e salvare librerie nel documento elettronico tramite API e CLI. Non è un editor PCB nell’app. T92 resta aperto per completare il catalogo e ampliare il corpus; T99 (Claude) collega il package e il documento all’app.

## Contratto per Claude: anteprima e conferma

```swift
let context = LibraryImportContext(
    key: LibraryRevision(id: stableLibraryID, revision: 1),
    source: LibrarySource(reference: sourceURL, license: licenseText, sourceRevision: sourceTag),
    assemblyCentroid: PCBPoint(0, 0)
)
let proposal = try KiCadLibraryImporter.footprint(sourceData, context: context)
let command = ElectronicsLibraryCommand.importLibrary(proposal)
let preview = try ElectronicsLibraryCommands.preview(
    command, document: document, expectedRevision: document.revision
)
// Mostrare preview.library e preview.issues; Esc scarta soltanto la proposta.
// OK usa la revisione dell’anteprima, NON una nuova revisione letta al momento del clic.
try ElectronicsLibraryCommands.apply(command, to: &document, expectedRevision: preview.baseRevision)
let saved = try document.encoded()
```

- Preview opera su una copia; conferma e anteprima usano la stessa validazione. Un’importazione confermata produce un solo passo di undo, persistente anche dopo riapertura. Reimportare dati identici è un’operazione nulla.
- Il documento scrive **formato 3** e legge i formati 1, 2 e 3. I dati opzionali assenti nei documenti precedenti, incluso lo schema, restano `nil`; geometria e storico sono conservati. I lettori precedenti rifiutano il formato nuovo anziché perdere i campi sconosciuti. Nessuna migrazione del documento CAD `.ftk`.
- `LibraryRevision` è UUID + revisione. L’app conserva l’UUID quando importa una nuova revisione della stessa libreria. Stessa chiave con contenuto diverso → errore atomico; una nuova revisione si aggiunge e non sostituisce quelle usate dai componenti esistenti.
- Pin e piazzole hanno ID derivati dall’identità della libreria e dagli identificatori sorgente. Nei formati senza UUID le piazzole usano numero/occorrenza, la grafica un indice: riordinare elementi legacy o piazzole con numeri duplicati può cambiare questi ID. Gli ID restano persistenti dopo conferma, undo e riapertura.
- `SymbolPin` contiene numero, tipo elettrico, posizione, angolo, lunghezza e stile; `LibraryGraphic` contiene primitive in mm, strato e ID. Il campo `sourceLayers` delle piazzole è la descrizione della libreria **prima** del posizionamento, non lo stack fisico trasformato sul lato inferiore.
- Gli avvisi d’importazione riportano l’ID della libreria; alcuni errori di piazzola riportano il relativo ID. `ElectronicsIssue` ammette posizione e soggetti. La copertura diagnostica generale E0 resta parziale: non tutte le verifiche restituiscono già ID/posizione.
- Queste primitive sono locali alla libreria. Lo schema espone ora snapshot, stile semantico e pick/snap indicizzati tramite [SCHEMATIC.md](SCHEMATIC.md); gli identificatori dei componenti sono condivisi con il PCB. Lo snapshot PCB completo resta E3. Non ricostruire nella UI le trasformazioni o la connettività dello schema.
- Nessun I/O o accesso alla rete implicito. L’app legge il file e passa `Data`; la CLI è l’adattatore su disco. I parser controllano la cancellazione. Le importazioni vanno eseguite fuori dal thread UI; nessun benchmark dimostra ancora i limiti interattivi di §4.

`LibraryImportResult` conserva testo sorgente UTF-8, SHA-256, provenienza nelle definizioni, formato e diagnostica. La conferma incorpora nel documento **le definizioni native e l’hash**, non tutto il sorgente: salvare il bundle accanto alla libreria se serve conservare anche i dati non convertiti. L’hash verifica la corrispondenza con il sorgente conservato, non la correttezza elettronica della conversione.

## Formati e copertura effettiva

| Formato | Importato | Rifiutato / segnalato |
|---|---|---|
| KiCad `.kicad_mod`, root `footprint` o legacy `module` | Impronte di libreria frontali; SMD e PTH; rettangolo, cerchio, ovale e rettangolo arrotondato con raggio; foro tondo centrato; strati, numeri, angoli; linee, rettangoli, cerchi, polilinee e archi a tre punti | Rifiutati NPTH, pad custom/trapezio, fori ovali/decentrati, padstack non rappresentabili, clearance/maschere personalizzate, grafica sul rame e politiche speciali di esclusione BOM/montaggio. Testo e riferimenti 3D restano nel sorgente con avviso. |
| KiCad `.kicad_sym` | Un simbolo scelto per nome; unità comune/prima e rappresentazione normale; pin e tipi elettrici; proprietà e geometria base; ereditarietà di proprietà sopra un simbolo base | Rifiutati multisezione, rappresentazioni alternative, override geometrico ereditato, cicli, simboli esclusi da scheda/BOM. Testo, preferenze di visualizzazione e alcuni stili rimangono nel sorgente con avviso. |
| EasyEDA **Standard** JSON `docType=4` | Impronta autonoma, origine esplicita; SMD top rettangolari/circolari/ovali, angoli multipli di 90°; segmenti grafici su strati cosmetici supportati; proprietà | Nessun supporto Pro, scheda completa, simboli, fori, pad obliqui/custom, espansioni maschera/pasta o rame grafico. Costrutti non rappresentati bloccano l’importazione; testo/3D danno avvisi. |
| Catalogo CSV normalizzato | Codice JLC/LCSC, produttore, MPN, package, descrizione, stock osservato, datasheet e colonne originali; mapping intestazioni configurabile | Non è un export ufficiale JLC inventato né una connessione live. Prezzi, ordini e verifica dell’assemblabilità non implementati. |

Le quote KiCad sono già in mm. Per le impronte si converte Y verso l’alto e si conserva l’angolo antiorario. Per EasyEDA Standard si sottrae l’origine, si inverte Y e si applica **0,254 mm per unità**; l’unità mostrata nel canvas non cambia i dati. EasyEDA Pro usa una convenzione distinta e viene rifiutato. Le diverse descrizioni storiche del campo foro Standard richiedono un corpus reale prima di abilitarne l’importazione.

Ogni impronta importata avverte di verificare il centro di presa. L’origine del file non certifica quel punto. I riferimenti 3D KiCad/EasyEDA non diventano automaticamente `ComponentModel3D`: occorrono acquisizione, licenza, verifica unità/orientamento e hash dell’asset (E5).

## Dispositivi e catalogo

`ElectronicsLibraryCommands.suggestedPinMap(symbol:footprint:)` propone l’associazione numero pin ↔ numero piazzola. Numeri mancanti/ambigui o piazzole non corrispondenti danno errore. La proposta **non crea un dispositivo**: controllare il datasheet, costruire `DeviceDefinition` e confermare `.createDevice(device)` con preview/revisione come sopra. La mappatura esplicita ammette più piazzole per un pin.

`ComponentCatalogImporter.csv(_:columns:sourceReference:observedAt:)` produce uno snapshot immutabile e serializzabile. `search` cerca codice, MPN, produttore, package e descrizione; una quantità assente è sconosciuta, non zero disponibile. `observationIsOlder(than:at:)` usa il tempo passato dal chiamante; nessuna rete o lettura d’orologio nascosta. La decodifica rifiuta versioni sconosciute, stock negativi e identità duplicate/incomplete.

`snapshot.jlcPart(number:for:)` accetta soltanto il produttore corrispondente e l’MPN esatto (sensibile a maiuscole/minuscole); restituisce il legame al catalogo con data, **senza inventare correzioni angolari**. Le alternative sono risultati di ricerca, mai sostituzioni automatiche. Il package e la piedinatura richiedono ancora revisione del progettista. Non sono disponibili prezzi aggiornati o garanzie di disponibilità attuale.

## CLI e prova riproducibile

```sh
bash scripts/test-electronics.sh
```

Esegue test Swift, CLI di assemblaggio e librerie e due lettori Python indipendenti. Genera sotto `build/electronics/run.XXXXXX/` anche contesti, bundle e documenti di esempio. Non sovrascrive output esistenti; errori producono exit 1 e nessun documento parziale.

```text
electronics-library kicad-footprint input.kicad_mod context.json output.json
electronics-library kicad-symbol input.kicad_sym context.json NomeSimbolo output.json
electronics-library easyeda-footprint input.json context.json NomeImpronta output.json
electronics-library catalog input.csv metadata.json output.json
electronics-library apply-import documento.json bundle.json revisioneAttesa output.json
```

`context.json` contiene `key: {id, revision}`, `source: {reference, license, sourceRevision}` e `assemblyCentroid: {x,y}`. Il catalogo usa `metadata.json` con `columns`, `sourceReference` e `observedAt` ISO 8601; intestazioni predefinite: `LCSC Part #,Manufacturer,MPN,Package,Description,Stock,Datasheet`. Gli esempi completi sono generati dal collaudo, partendo da `Tests/Electronics/check_library.py`.

Limiti parser: 16 MiB per sorgente, profondità S-expression 64, 500.000 nodi. Questi limiti proteggono l’importazione, non dimostrano prestazioni su grandi cataloghi. Il documento resta limitato a 64 MiB e usa snapshot per lo storico.

## Fonti primarie studiate

- [KiCad S-expression](https://dev-docs.kicad.org/en/file-formats/sexpr-intro/) e [librerie simboli](https://dev-docs.kicad.org/en/file-formats/sexpr-symbol-lib/).
- [EasyEDA Standard](https://docs.easyeda.com/en/DocumentFormat/EasyEDA-Format-Standard/), [formato PCB](https://docs.easyeda.com/en/DocumentFormat/3-EasyEDA-PCB-File-Format/) e [unità API Standard](https://docs.easyeda.com/en/API/EasyEDA-API/).
- [Unità API EasyEDA Pro](https://prodocs.easyeda.com/en/api/reference/pro-api.sys_unit.html): separazione esplicita da Standard.
- [JLCAPI](https://api.jlcpcb.com/): servizio da collegare con contratto pubblico e credenziali dell’account; nessuna richiesta autenticata eseguita.

Nessun codice di motori esterni copiato o collegato. Il corpus KiCad 9.0.0 è attribuito al KiCad Library team e include la licenza upstream. Le prove EasyEDA/catalogo sono sintetiche: non sostituiscono un’importazione di componenti reali JLC/LCSC o il controllo del datasheet.
