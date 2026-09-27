# Accettazione dell'importazione revisionata nell'app

27/09/2026 · T107 Codex, integrazione T97 Claude. Solo dati sintetici e una build
Debug separata; nessun progetto reale. Esito della prova in [VALIDATION.md](VALIDATION.md).

Preparazione riproducibile, dalla radice del repository:

```sh
swift build --package-path Packages/ElectronicsCore
electronics_bin=$(swift build --package-path Packages/ElectronicsCore --show-bin-path)
python3 Tests/Electronics/check_revision_ui.py prepare "$electronics_bin/electronics-library" build/electronics/acceptance-107/nuova-prova
```

La directory deve essere nuova. Il generatore usa il campione KiCad attribuito del
corpus per creare due file omonimi in `v1/` e `v2/`: centri piazzole da ±0,825 a
±0,925 mm, ID stabili. La fixture `01-iniziale.ftkc` contiene sei componenti:
R1–R5 usano la revisione 1; R6 un dispositivo distinto, non interessato.
I componenti sono sintetici: non autorizzano acquisti o fabbricazione.

1. Aprire `01-iniziale.ftkc` in Circuiti. Libreria → Importa →
   `v2/QA_Revision_R0603.kicad_mod`.
2. Verificare revisione 1→2, due piazzole modificate, quote prima/dopo,
   sovrapposizione delle geometrie e riferimenti R1–R5. R6 deve essere escluso.
3. Annullare e premere Salva. Conservare una copia del file salvato come
   `02-annullato.ftkc`: documento e storico invariati.
4. Ripetere l'import e confermare. Salvare e conservare una copia `03-importato.ftkc`:
   nuova revisione disponibile, R1–R5 ancora agganciati alla 1, un solo passo di undo.
5. Annulla → salvare e conservare `04-undo.ftkc`. Copiarlo in `05-redo.ftkc`,
   aprire quest'ultimo nell'app e Ripeti → Salva. Il redo deve sopravvivere alla riapertura.
6. Importare lo stesso file senza cambiamenti da un'altra cartella (stesso nome):
   avviso di contenuto già presente; conferma senza nuovi passi di storico.
7. Importare `QA_Shapes.kicad_mod` per la prova grafica: piazzola rettangolare,
   ovale, con raggio esplicito e passante. Il foro resta vuoto; le forme ruotate
   stanno nei limiti mostrati. Non dedurre l'ingombro meccanico da questa anteprima.

Controllo indipendente dei file salvati dalla UI:

```sh
python3 Tests/Electronics/check_revision_ui.py check DIRECTORY DIRECTORY/02-annullato.ftkc unchanged
python3 Tests/Electronics/check_revision_ui.py check DIRECTORY DIRECTORY/03-importato.ftkc imported
python3 Tests/Electronics/check_revision_ui.py check DIRECTORY DIRECTORY/04-undo.ftkc undone
python3 Tests/Electronics/check_revision_ui.py check DIRECTORY DIRECTORY/05-redo.ftkc redone
```

Il lettore confronta il documento completo, inclusi componenti, collegamenti,
rame e definizioni precedenti. Verifica geometria/ID della revisione aggiunta e
la catena di storico. Il generatore usa la CLI solo per preparare e validare i dati:
un suo risultato positivo non equivale a un'azione eseguita nell'app.
`00-baseline.json` conserva il riferimento iniziale: non viene sovrascritto dai
salvataggi della UI. Le copie di archivio si fanno solo sui file della directory
QA; il documento esistente viene salvato dal pulsante Salva del circuito.

Nel ponte app, Claude deve verificare con worker sospesi: cambio di revisione,
documento nuovo, riapertura dello stesso file, annullamento e nuovo import più
recente. Vale sia per l'enumerazione/scelta dei simboli sia per l'anteprima finale.
Nessuna proposta tardiva deve comparire o applicarsi a un altro documento.
