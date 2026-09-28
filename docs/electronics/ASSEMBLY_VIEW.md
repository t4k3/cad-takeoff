# Scheda assemblata — T111

Contratto Codex → Claude, 28 settembre 2026. Implementazione in corso.

Obiettivo: vedere i componenti sulla scheda Gerber/BOM/CPL, selezionarli con gli stessi
UUID della distinta, distinguere montati/esclusi e qualità del modello. Non ricostruisce
lo schema elettrico, non certifica ingombri o collisioni da modelli approssimati.

## API concordata per l'app

`ManufacturingAssemblySnapshot(package: ManufacturingPackage,
previous: ManufacturingAssemblySnapshot? = nil) throws` (Sendable,
immutabile, costruzione fuori MainActor, cancellabile). Proprietà pubbliche:

- `packageID: UUID`, `instances: [ManufacturingAssemblyInstance]` (anche mancanti/esclusi).
- `boardThickness: Double`, `isBoardThicknessAssumed: Bool` (1.6 mm solo convenzione
  visuale quando l'utente non ha specificato lo spessore).
- `boardParts: [ManufacturingAssemblyPart]` (substrato da contorno reale e fori;
  se il contorno non è ricostruibile, nessun rettangolo inventato e avviso).
- `issues: [ElectronicsIssue]` con UUID e posizioni, in italiano.
- `pick(point: PCBPoint, tolerance: Double, side: BoardSide? = nil,
  includeExcluded: Bool = false) -> [ManufacturingPick]` per corpi e centri senza modello.
- `snapTargets(near: PCBPoint, radius: Double, side: BoardSide? = nil,
  includeExcluded: Bool = false) -> [ManufacturingSnapTarget]`.

Passare l'ultimo snapshot in `previous` durante anteprima/cambio lotto: il substrato si
riusa solo se UUID, profilo, forature e spessore coincidono esattamente. Corpi, indici
di scelta e diagnostica dei componenti vengono aggiornati; nessuna cache globale.

Tipi definiti in `ManufacturingAssemblyModels.swift`. `parts` dell'istanza sono mesh
**già nel sistema documento**, mm/Z-up, triangoli CCW verso l'esterno; `polygons` sono
proiezioni 2D già trasformate (ogni parte è convessa nel catalogo iniziale), ordinate
dal fondo verso l'osservatore del lato del componente: disegnarle nell'ordine fornito.
L'ordinamento usa la superficie più vicina, poi il centro dell'intervallo Z; evita che
i terminali sotto i condensatori coprano il corpo. Per parti inclinate o intersecanti
la visibilità per sagome resta approssimata: la mesh 3D è il riferimento. Materiali
semantici, colori scelti dalla UI. `pinOne` è il testimone del modello già trasformato;
orientamento CPL da verificare, mai dichiarato certo per una sola corrispondenza di nome.
Nessuna dipendenza da CADCore/AppKit/SwiftUI/Metal.

`ManufacturingPackageCatalog.models: [ManufacturingPackageModel]` è il catalogo per il
picker; `model(key:)` risolve chiavi versionate; `suggestedModel(for:)` propone solo
impronte riconosciute senza inferire dal solo codice LCSC. Tutti i modelli iniziali sono
**approssimati**, con fonte/assunzioni disponibili. Un componente sconosciuto resta senza
corpo: indicatore e riga distinta, nessun parallelepipedo spacciato per modello esatto.

Comandi `ElectronicsCommand.manufacturing(...)`, stesso preview/apply/expectedRevision:

- `.setBoardThickness(Double?)`: nil ripristina la convenzione dichiarata.
- `.setComponentModel(componentID: UUID, binding: ManufacturingModelBinding?)`: nil
  ripristina il suggerimento automatico; binding contiene `modelKey`, `offset: PCBPoint3`,
  `rotationDegrees: PCBPoint3` e `alignmentVerified: Bool`.

Rotazioni locali Euler Rz*Ry*Rx, poi offset locale, poi trasformazione CPL. Lato sotto =
rotazione rigida Y di 180°, poi rotazione CPL; le coordinate/rotazioni del CSV originale
non cambiano. Una conferma allineamento non trasforma un corpo generico in modello
dimensionale verificato. I controlli offset e rotazione devono avere anteprima/OK/Annulla.

Persistenza formato **9**, lettura 1–8 compatibile; i nuovi campi sono opzionali per i
vecchi documenti. Le app precedenti rifiutano il 9 anziché perdere i nuovi dati.
Assemblaggio e allineamenti sopravvivono a salva/riapri/annulla/ripeti e cambio lotto.

## Limiti della prima consegna

Catalogo proprietario di package comuni, non fotorealistico né certificato dal produttore.
Modelli specifici STEP/OBJ/STL e catalogo remoto JLCPCB saranno un passaggio distinto;
nessun accesso API o scaricamento modelli è dato per disponibile. Non inviare la scheda
del cliente a servizi esterni. Il rame continua a provenire dal renderer CAM già verificato.

### Catalogo v1 e fonti delle dimensioni

15 modelli: resistenze/condensatori 0805 e 1210, elettrolitico 6,3 × 7,7 mm,
SOT-23 a 3/6 piedini, SOD-923/323/123, SMA e strip maschio verticali 2,54 mm
1×2/1×3/1×4/2×3. Le chiavi `.v1` restano immutabili; una geometria diversa richiede
una chiave nuova. I modelli derivano da generatori interni, con parti convesse separate,
senza importare codice o mesh di librerie esterne.

Fonti studiate per gli ingombri nominali:

- [Vishay D/CRCW](https://www.vishay.com/docs/20035/dcrcwe3.pdf),
  [Murata GRM](https://www.murata.com/products/capacitor/ceramiccapacitor/overview/lineup/smd/grm).
- [Nexperia SOT23](https://www.nexperia.com/packages/SOT23.html),
  [TI DBV a sei piedini](https://www.ti.com/lit/ds/symlink/sn74lvc2g17.pdf).
- [onsemi SOD923](https://www.onsemi.com/pdf/datasheet/esd9p5.0s-d.pdf),
  [NXP SOD323](https://www.nxp.com/packages/SOD323),
  [Nexperia SOD123](https://www.nexperia.com/packages/SOD123),
  [Vishay SMA](https://www.vishay.com/docs/88367/p4sma.pdf).
- [Samtec TSW](https://www.samtec.com/products/tsw) come riferimento di famiglia;
  altezza isolante, lunghezza e sezione pin dei modelli generici restano assunte.

Altezze e terminali generici, tolleranze, saldature e orientamento rispetto al CPL non
sono certificati dal solo nome del footprint. Le assunzioni sono in `model.source`,
visibili nella UI. I nomi contraddittori (`DO-214AC_SMB`) o non sufficienti (`LM1117`)
rimangono senza suggerimento. Non si cerca di indovinare la forma dal codice LCSC.

### Substrato e prestazioni

Il substrato deriva dagli anelli chiusi del profilo e da fori/asole del pacchetto.
Le forature sono poligoni con almeno 32 lati e freccia massima 0,01 mm, non superfici
analitiche. Contorni aperti, ramificati, sovrapposti o fori che richiedono unioni non
supportate producono un avviso; non sono sostituiti da un rettangolo pieno. La geometria
3D è derivata e non viene duplicata nel documento o nello storico.

`electronics-assembly documento.ftkc nuovo-report.json` produce mesh, istanze e avvisi
per controlli indipendenti senza scrivere il documento originale né sovrascrivere il report.
`Tests/Electronics/check_manufacturing_assembly.py` verifica chiusura e winding dei
triangoli, trasformazioni rigide, identità, lotti e assenza di posizioni inventate.

## Prove da registrare

Orientamenti top/bottom con rotazioni arbitrarie e offset non nulli; mesh chiuse e winding;
lotto montati/esclusi; componenti senza posizione; selezione; storico e migrazione;
preview senza mutazioni e revisione stale; dati Ballgun e verifica visiva app 2D/3D.
