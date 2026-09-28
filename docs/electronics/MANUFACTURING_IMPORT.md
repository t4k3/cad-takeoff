# Importazione Gerber, BOM e posizioni — T108

Contratto implementato nel motore, 28/09/2026. Codex: motore; Claude/T97: app.

Ross conferma che la BOM può escludere intenzionalmente componenti per un lotto.
L'importazione conserva la scheda completa e separa la scelta di montaggio.
Un componente presente nei Gerber o nelle posizioni ma assente dalla BOM rimane
nel documento, escluso dal lotto importato. Nessuna eliminazione automatica.

## API

```swift
ElectronicsManufacturingImport.prepare(
    archive: Data, bom: Data, positions: Data,
    name: String, lotName: String = "Lotto importato"
) throws -> ManufacturingPackage

ElectronicsCommand.manufacturing(ManufacturingCommand.importPackage(package))
ManufacturingCommand.setFitted(componentID: UUID, fitted: Bool)
ManufacturingCommand.addLot(id: UUID, name: String) // copia il lotto attivo
ManufacturingCommand.selectLot(UUID)
```

Usare `ElectronicsCommands.preview/apply` con `expectedRevision`, stessa istanza
di comando tra anteprima e conferma. Stato in `design.manufacturing` opzionale,
persistenza attuale formato 9 (lettura 1–9; T108 introdusse il formato 8).
Un passo per importazione o modifica lotto.
Parser, validazione e snapshot in background cancellabile; l'app aggiunge chiave
documento/epoca/revisione e token come l'importatore di librerie. Nessuna rete o
I/O nel core. Il lettore ZIP lavora in memoria, usa solo libz del sistema Apple
per la decompressione; nessun package esterno.

`ManufacturingPackage`: `id`, `name`, `layers`, `drills`, `components`, `lots`,
`activeLotID`, `sources`, `bounds`, `issues`, `assemblySettings` opzionale.
`activeLot` e `isFitted(UUID)`.
`ManufacturingComponent`: ID stabile, `reference`, `value`, `footprint`,
`lcscPartNumber`, `placement` opzionale (position, rotationDegrees, side),
`modelBinding` opzionale per l'allineamento visuale, senza cambiare la CPL.
`ManufacturingLot`: `id`, `name`, `fittedComponentIDs`, `bomSHA256` opzionale.
Assenza di posizione o codice non equivale a componente assente.

Geometria sempre in mm, vista dall'alto su entrambi i lati, coordinate originali
anche negative. Nessuna specchiatura/ricentratura implicita.
`ManufacturingLayer`: id/name/kind (FabricationLayerKind)/primitives.
`ManufacturingPrimitive`: id, shapes, isDark, netName/componentReference/pinNumber.
`ManufacturingShape`: contours [[PCBPoint]], radius, isDark. A raggio zero i contorni
sono riempiti even-odd; un punto + raggio è un disco, due punti + raggio una capsula.
Comporre le shapes in ordine su una maschera trasparente del singolo oggetto
(isDark=false sottrae localmente); applicare poi l'oggetto allo strato secondo la
sua polarità. Non sottrarre un foro di apertura direttamente dagli oggetti sottostanti.
`ManufacturingDrill`: id,position,end opzionale (asola),diameter,isPlated.

Il renderer non interpreta il Gerber né ricostruisce forme locali.
`ManufacturingSnapshot(package:)` costruisce un indice immutabile in background.
`pick(point:tolerance:layerIDs:)` e `snapTargets(near:radius:layerIDs:)` forniscono
ID/punti. Filtri per UUID degli strati; componenti e fori hanno selezione propria.
Il picking verifica la composizione delle polarità; con tolleranza positiva usa
test conservativi sul bordo e può omettere intersezioni ritagliate molto piccole.
Diagnostica italiana con ID soggetti e posizione quando disponibile.

## Integrazione app

Importare in un circuito vuoto oppure aggiungere un lotto allo stesso pacchetto
geometrico; mai sovrapporre silenziosamente una scheda importata a un PCB nativo.
Mostrare gli strati, i fori e i riferimenti alle posizioni, tabella componenti con
controllo Monta, selettore lotti e avvisi. Conservare quelli esclusi sul disegno.
Non abilitare modifiche delle piste native, DRC/ERC nativi o export di produzione
rigenerato su questa geometria CAM. T111 introduce il contratto dedicato
[Scheda assemblata](ASSEMBLY_VIEW.md), con modelli generici esplicitamente approssimati.
Schema originale, storico precedente e modelli 3D non sono presenti nei tre file.
Mostrare questo limite in modo breve; lo storico dell'importazione è invece reale.

## Caso reale privato

File originali in Downloads, mai copiati nel repository: Ballgunmain_hw.zip,
bom.csv, positions.csv. Scheda 65 × 81 mm, 9 strati Gerber + 2 mappe fori,
150 fori PTH tondi, 4 NPTH e 4 asole PTH: 158 oggetti di foratura totali.
BOM 49 righe/84 riferimenti; CPL 85 (84 top, T1 bottom).
T1 assente dalla BOM: escluso dal lotto. J8 senza LCSC: mantenuto e segnalato.
IC2 è presente solo negli attributi Gerber: conservato senza inventarne il centro
di posizionamento. Totale 86 riferimenti, 84 da montare nel lotto iniziale.
Gerber con attributi KiCad commentati per reti/pin, macro RoundRect, archi e clear.
Questi dati sono verificati dal lettore indipendente e dal test reale del motore.
La prova nell'app è registrata separatamente in VALIDATION.md.

## Storico e conservazione dei lotti

Dal formato8, anche nel formato9: `manufacturingGeometry` alla radice del documento conserva una volta
sola layers/drills/bounds per UUID pacchetto. Gli stati correnti/past/future
mantengono i metadati e i lotti e referenziano `geometryID`. La lettura espande in
memoria array condivisi; nessuna duplicazione dell'artwork a ogni casella Monta.
Rimane leggibile la rappresentazione inline v8 iniziale. Riferimenti mancanti e
geometrie diverse con lo stesso UUID vengono rifiutati.

Reimport dello stesso pacchetto: conserva componenti omessi da entrambe le tabelle,
aggiunge il lotto con nome nuovo, non modifica gli altri lotti. Cambi di valore,
impronta, codice LCSC o posizione già noti sono conflitti espliciti: questa prima
versione gestisce omissioni, non sostituzioni di componenti tra lotti.

## Riferimenti

- [Gerber Ucamco, specifica 2026.05](https://www.ucamco.com/files/downloads/file_en/554/gerber-layer-format-specification-revision-2026-05_en.pdf)
- [BOM JLCPCB](https://jlcpcb.com/help/article/bill-of-materials-for-pcb-assembly)
- [CPL JLCPCB](https://jlcpcb.com/help/article/pick-place-file-for-pcb-assembly)

## Formati e limiti della prima consegna

- ZIP32 stored/deflate, CRC e coerenza indice/dati verificati, nessuna estrazione
  su disco. No ZIP64/cifratura/multidisco/link. Massimo64MiB ZIP,256voci,
  32MiB/file,128MiB espansi; limiti ulteriori dei parser.
- CSV UTF-8 anche con BOM, separatore virgola/punto e virgola, campi quotati e
  riferimenti raggruppati. Quantità coerenti, ID unici, DNP/Fitted espliciti.
  CPL in mm con coordinate/rotazioni originali, top/bottom; nessuna origine indovinata.
- Gerber assoluto, soppressione zeri iniziali/finali, mm/inch, aperture C/R/O/P,
  macro1/4/5/20/21 e aritmetica, flash, tratti circolari, regioni, G75/G02/G03.
  Archi discretizzati con errore di corda massimo0,01mm. Polarità e attributi
  TF/TO/TD formali o commentati KiCad. Mappe fori ignorate se identificate come tali.
- Excellon/XNC decimale esplicito, PTH/NPTH, fori tondi, G85 e asole G00/M15/G01/M16.
  Il formato a interi senza precisione, routing circolare e ripetizioni non vengono indovinati.
- Rifiuto esplicito di strati interni, formati/comandi sconosciuti, SR/AB,
  trasformazioni LM/LR/LS, G74, coordinate incrementali e associazione di un oggetto
  a più reti. File accessori PDF/gbrjob/metadati macOS sono segnalati; altri file
  sconosciuti bloccano l'importazione anziché sparire.
- Nei pacchetti salvati: massimo250.000 primitive/2milioni di vertici,
  100.000 forature/20.000componenti/1.000lotti, coordinate entro±100.000mm.
  I singoli lettori possono applicare limiti più restrittivi.

`bash scripts/test-electronics.sh`:219 test Swift (uno reale opzionale saltato)
e otto lettori Python PASS. Test reale eseguito separatamente:100 modifiche lotto,
undo/riapertura/redo PASS, documento7.064.700byte. Vedere VALIDATION.md per log.
