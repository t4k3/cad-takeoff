# Fabbricazione a due strati — T103

API additive compilanti al 27/09/2026; formato documento **7 invariato**.
La prima consegna copre un pacchetto coerente da collaudare: non qualifica componenti,
processo JLCPCB o circuito elettrico. T92/T94/T95 avanzati restano aperti.

L'app espone ora **Circuiti → Produzione → Gerber**: profilo, variante, anteprima
strati, problemi selezionabili ed export in una cartella nuova. Quattro export
nativi della fixture sono verificati in [VALIDATION.md](VALIDATION.md); procedura
ripetibile in [APP_ACCEPTANCE.md](APP_ACCEPTANCE.md). Il preflight è disponibile
anche tramite `circuit_fabrication_check`: [contratto assistente](ASSISTANT.md).

## Contratto per app, chat e MCP

```swift
let preview = try ElectronicsFabrication.preview(
    document: document, expectedRevision: revision,
    profile: FabricationProfile(), variantID: nil)
// preview.canExport; preview.issues; preview.layers; preview.drills
let package = try ElectronicsFabrication.export(
    document: document, expectedRevision: revision,
    profile: profile, variantID: variantID)
// package.preview, package.files: [FabricationFile(name:content:)]
```

Entrambe le chiamate sono pure, senza I/O o rete, cancellabili e senza modifiche allo
storico. `export` ripete il preflight sul valore del documento ricevuto; una revisione
obsoleta è rifiutata anche dopo Annulla. `FabricationPreview` contiene identità del
progetto, revisione, variante, origine e profilo esatti; `canExport` significa solamente
assenza di errori **nel perimetro descritto qui**. Gli avvisi vanno mostrati.

Claude: worker in background come per i piani. Accettare il risultato solo per
UUID/revisione/token, profilo e variante ancora correnti. L'export non è una modifica
geometrica e non aggiunge un passo Annulla. Prima di scrivere il risultato ricontrollare
identità/revisione e gli altri parametri; non pubblicare un pacchetto superato mentre
il worker elaborava. Scrivere in una directory temporanea e rinominarla soltanto quando
tutti i file sono pronti; preservare export precedenti e modifiche del documento.
L'assistente deve chiamare queste API, senza comporre Gerber o correggere il rame da sé.

### Disegno dell'anteprima

`layers: [FabricationLayer]`, ordinate rame top/bottom, maschera top/bottom,
pasta top/bottom, serigrafia top/bottom, contorno. Ogni oggetto ha `subjectIDs` stabili:

- `flash`: nucleo convesso `core` espanso da un disco `radius` (piazzola/via).
- `stroke`: polilinea `core` a terminali tondi, larghezza `2 * radius`.
- `region`: poligono pieno `core`; `radius == 0`.

Sono tutte coordinate **del documento in mm**, viste dall'alto anche sul lato inferiore.
Le aperture della maschera descrivono il materiale **assente**. `drills` sono vuoti
separati: posizione, diametro e soggetti. Il profilo ha spessore zero, da disegnare con
un tratto convenzionale a schermo. Nessun riflesso o altra trasformazione lato UI.
Gli errori ERC possono avere posizione sullo schema: selezionare il componente/pin
tramite gli ID, senza reinterpretare quella posizione come coordinata PCB.

## Preflight

Riusa DRC, rame finale e ERC del motore; nessun secondo riempimento indipendente:

- Errori DRC del rame bloccanti: corti, clearance, bordo, dimensioni, fori, termiche,
  colli e keepout. Airwire, rame flottante e piani vuoti diventano errori per l'export.
- Ogni componente deve essere piazzato, anche DNP: l'impronta resta sulla scheda.
- Pin senza rete/NC, ingressi o alimentazioni privi di sorgente dichiarata e fili
  pendenti bloccano l'export; restano i limiti dell'ERC iniziale, non una simulazione.
- Distanza tra fori distinta dalla clearance elettrica, anche sulla stessa rete.
- Minimo intervallo fra aperture maschera (anche della stessa rete); nessuna fusione
  implicita delle aperture e nessuna eccezione automatica per fine pitch.
- Spessore dei tratti serigrafici, distanza dalle aperture e contenimento nella scheda.
  La serigrafia in conflitto viene diagnosticata, non cancellata o tagliata di nascosto.
- Riduzione pasta che annulla una piazzola, strati grafici produttivi non rappresentati,
  regioni degeneri dopo quantizzazione e più di 99 diametri di foratura sono rifiutati.
- Requisiti BOM/CPL esistenti: un componente assegnato a JLC deve avere codice e regola
  di rotazione verificata per il lato usato; nessuna riga mancante ignorata.

`FabricationProfile` esplicita espansione maschera (0,05), riduzione pasta (0), minimo
intervallo maschera (0,1), larghezza serigrafia (0,15), distanza serigrafia-aperture
(0,1), distanza tra fori (0,25 mm), via coperti (`tentVias=true`). Sono valori generici
configurabili, **non un profilo JLC certificato**. Restano incorporati nel manifest;
non vengono salvati automaticamente nel documento o dedotti dal produttore.

I layer sorgente dei pad sono rispettati, compresi pad senza pasta e maschera
aperta solo da un lato del PTH; il flip di una piazzatura bottom avviene una volta.
Una variante di montaggio o DNP esclude la pasta e il montaggio del componente,
conservando rame, maschera, fori e serigrafia.

## File

- Nove Gerber X2 (`board-*.gbr`), con FileFunction, FilePolarity e coordinate comuni.
  Pad come flash C/macro, piste come tratti a sezione circolare, rame dei piani come
  regioni del riempimento finale: ostacoli, termiche e isole sono già risolti.
- `board-PTH.drl`: XNC, sottoinsieme Excellon con coordinate decimali esplicite in mm,
  soli PTH tondi, diametri finiti dopo metallizzazione; massimo 99 utensili.
- `board.gbrjob`: strati/file, dimensione, spessore e identità/revisione del progetto.
- `assembly-bom.csv` e `assembly-cpl.csv`: medesime API E0, solo componenti JLC montati.
- `components.csv`: elenco completo, incluse parti manuali e DNP, centro di montaggio,
  lato e angolo del documento (non la correzione angolare JLC del CPL).
- `preflight.json`, `README.txt`, `manifest.json`: parametri, avvisi, perimetro e SHA-256
  di ogni file salvo il manifest stesso. CryptoKit di sistema Apple; nessun package esterno.

`assemblyOrigin` è sottratta uniformemente da Gerber, forature e CSV; l'anteprima
conserva le coordinate originali. Il lato inferiore **non viene specchiato nell'export**.
Coordinate Gerber 6.6, apertura/macro 9 decimali, forature 6 decimali; arrotondamento
coordinate massimo 0,0000005 mm per asse. Nessuna data casuale nel contenuto:
lo stesso documento/profilo/variante produce gli stessi byte e hash.

## Perimetro e limiti

Due strati, contorno semplice a segmenti, pad SMD/PTH circolari, rettangolari, ovali o
arrotondati, via passanti, piste polilineari, piani/termiche. Serigrafia di libreria:
linee, rettangoli, polilinee, cerchi e archi; curve serigrafiche approssimate con freccia
massima 0,002 mm, considerata anche nel controllo di distanza dalle aperture.
Nessun testo inventato da nome/reference: la grafica deve esistere in libreria.
I livelli Fab/CrtYd sono informativi e non finiscono nella serigrafia.

NPTH di fissaggio, asole, ritagli interni, padstack speciali, via ciechi/interrati,
stackup dielettrico, impedenza, rame multilayer e priorità avanzate non sono coperti.
L'assenza di NPTH nel modello non autorizza a trasformare un cerchio Fab in una foratura.
Non sono coperti i minimi colli delle grafiche serigrafiche piene, le compensazioni di
processo, le dimensioni massime di tenting né la qualifica termica/elettrica del rame.
I modelli 3D, pin 1, dati dei componenti, disponibilità del catalogo e viewer del
fornitore richiedono ancora accettazione separata. La fixture è sintetica e marcata
come tale: non è una scheda qualificata o un ordine di produzione.

## Prova riproducibile

```sh
swift run --package-path Packages/ElectronicsCore electronics-fabrication \
  Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/fabrication.json \
  build/electronics/nuovo-pacchetto
python3 Tests/Electronics/check_fabrication.py build/electronics/nuovo-pacchetto \
  Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/fabrication.json \
  Packages/ElectronicsCore/.build/debug/electronics-fabrication
```

La CLI rifiuta una destinazione già presente; gli errori non lasciano cartelle parziali.
Il lettore Python separato controlla sintassi emessa, forme rispetto al documento
sorgente, tutti i tipi di pad, rotazione/bottom, maschera/pasta, piste, profilo, fori,
origine comune, job, CSV e hash. Non è un parser Gerber generale o il viewer JLC.
Ulteriori evidenze in [VALIDATION.md](VALIDATION.md).

## Specifiche studiate

- [Ucamco Gerber Layer 2026.05](https://www.ucamco.com/files/downloads/file_en/554/gerber-layer-format-specification-revision-2026-05_en.pdf)
- [Ucamco XNC 2021.11](https://www.ucamco.com/files/downloads/file_en/452/xnc-format-specification-revision-2021-11_en.pdf)
- [Schema Gerber Job](https://www.ucamco.com/files/downloads/file_en/397/gerber-job-file-schema_en.json)

Implementazione propria; nessun codice o libreria CAD esterna incorporati.
