# Affidabilità della mappa — T02

Revisione 1 · 25 settembre 2026 · autore Codex.

## Risultato e identità

**Mappa esplorativa manuale/testuale, parziale. Non è un code graph semantico.**
La specifica è curata in `graph-spec.json`; il dataset canonico generato è
`graph.json`, da cui derivano HTML e Mermaid.

Checkout: `/Users/ross/APP varie/FUSION-TAKEOFF`. Progetto/scheme:
`FusionTakeoff.xcodeproj` / `FusionTakeoff`. Configurazione osservata: Debug,
macOS, arm64. Toolchain rilevata: Xcode 27.0 (27A266a), Swift 6.4;
linguaggio del progetto Swift 6, deployment target macOS 14.

Branch, commit se esistente, stato dirty, data UTC e versioni effettive sono
registrati in `graph.json.identity`. Il repository iniziale non ha un commit
di riferimento; gli hash SHA-256 identificano lo snapshot. I successivi commit
non sostituiscono il controllo dei file effettivamente letti.

## Copertura misurata nello snapshot iniziale

| Misura | Risultato |
|---|---:|
| File sorgente attivi trovati/inventariati | 10 / 10 |
| File con almeno un tipo mappato | 10 |
| Tipi/confini selezionati | 21 |
| Archi | 37 |
| SYNTACTIC | 31 |
| INFERRED | 1 |
| RUNTIME/EXTERNAL | 5 |
| RESOLVED / AMBIGUOUS | 0 / 0 |
| File analizzati da parser semantico | 0 |

L'inventario di tutti i file **non** equivale a copertura di tutti i simboli,
metodi, overload o dipendenze. Le conformance mostrate sono un campione.
Non è stato eseguito un parser AST: `parseErrors: null` significa non misurato,
non zero errori di risoluzione.

Inclusi: `App/Sources/**` e `Packages/CADCore/Sources/CADCore/**`. I test vengono
tracciati per rilevare cambiamenti, ma i loro archi non sono estratti. Esclusi:
archivio storico, codice generato dalle macro, internals dei framework Apple,
runtime GPU, eventuali altre configurazioni e piattaforme. Per il conteggio
aggiornato leggere `graph.json.coverage` dopo ogni rigenerazione.

## Metodo e freschezza

Per ogni nodo sorgente si verifica una dichiarazione; per ogni arco si verifica
un frammento esplicito con file/riga, SHA-256, target, stato semantico e motivo
dell'incertezza. Un anchor assente o ambiguo interrompe la generazione.
Le occorrenze multiple note sono indicate esplicitamente nella specifica.

`architecture_graph.py check` confronta inventario, hash dei sorgenti/test,
configurazione Xcode/package, generatore, specifica e template; verifica anche
la coerenza delle viste HTML e Mermaid col dataset. Un file aggiunto, rimosso o
modificato produce `STALE`. Il confronto non aggiorna da solo la classificazione:
dopo cambiamenti sostanziali occorre rileggere la specifica e le sonde.

**FRESH_EXPLORATORY significa snapshot allineato, non semantica risolta.**
Il generatore rifiuta `RESOLVED`. Per usare tale stato serve un futuro estrattore
basato su IndexStore/SourceKit con simboli risolti e copertura dichiarata.

## Sonde sul sorgente

| Sonda | Esito / limite |
|---|---|
| Ereditarietà, conformance, enum | `DesignModel` non dichiara superclass; i tipi struct hanno conformance. `Feature.Kind` è enum con payload, non raw value. Nessun arco di ereditarietà inventato. |
| Funzione numerica e chiamanti | Letta la catena `Profile2D.triangulate → Operations.extrude → Primitives/Feature`; chiamanti risolti semanticamente: zero. Test numerici separati. |
| View e stato osservabile | `ContentView`/`InspectorView` usano `@Environment` e `@Bindable`; la app mantiene `DesignModel` in `@State`. Espansioni delle macro escluse. |
| Combine | Nessuna catena esplicita `sink/assign/Publisher` nello snapshot; Observation non è stata classificata come Combine. |
| Task/await/actor | `@MainActor` in Model, nessuna catena esplicita `Task/await` nello snapshot; nessun actor hop dedotto. |
| Protocol witness/delegate | `NSViewRepresentable.updateNSView` è callback del framework, rappresentata `RUNTIME/EXTERNAL`. |
| Confine Objective-C/C | AppKit/SceneKit chiamati da Swift; nessun target C/C++ o bridging header locale. Interni del framework non ricostruiti. |
| Target/runtime esterno | Dipendenza app → CADCore e file I/O `.ftk/.stl`; nessuna prova di scrittura disco o import slicer dal grafo. |
| Falso positivo di codice morto | `STLExporter.ascii` non è usato nella UI, ma è API pubblica testata: nessuna conclusione di codice morto. |
| Campione casuale di classificazione | Seed 20260925 → E022 `CADDocument → Mesh`, chiamata `Mesh.merged`. Presenza e relazione lette nel sorgente; rimane `SYNTACTIC`. Nessun arco ad alta confidenza semantica disponibile. |

Il dataset conserva anche l'inventario delle occorrenze letterali per categoria.
Non sommarle come dipendenze uniche. Con nuovi file o feature, le sonde descritte
come assenti vanno rieseguite: questo rapporto non copre automaticamente codice futuro.

## Verifiche eseguite

- `swift test --package-path Packages/CADCore`: **6 test Swift Testing passati**,
  exit 0, eseguiti da Codex dopo la riconciliazione e dopo la separazione Model/UI.
  Il messaggio XCTest «0 tests» è il runner separato: i sei test sono nel risultato Swift Testing.
- T00/T16: Claude ha registrato build e avvio; Codex ha verificato il log
  `build/xcodebuild.log` contenente `BUILD SUCCEEDED`. T02 non ha modificato app/core.
- `python3 scripts/graph.py validate`: **24 task, nessun ciclo** al controllo.
- Verifiche del generatore: snapshot coerente accettato; hash deliberatamente
  stale respinto; anchor assente respinto; anchor ambiguo respinto; tentativo di
  promuovere un arco a `RESOLVED` respinto. **5 verifiche passate** senza modificare i sorgenti.
- HTML aperto nel browser locale e ispezionato visivamente; ricerca «STL» →
  5 relazioni, filtro `RUNTIME/EXTERNAL` → 3, selezione `DesignModel` → 12
  collegamenti. La pagina contiene i dati e funziona senza CDN o richieste esterne.

Non eseguiti da T02: revisione UX completa dell'app, prove GPU Metal, import
nello slicer, stampa reale, distribuzione firmata. Non sono implicati da build o test.

## Usi consentiti e non dimostrati

Adatto a navigazione, inventario, comunicazione tra agenti e formulazione di
ipotesi per un'analisi d'impatto. Prima di cambiare una API, rileggere chiamanti
e test nel sorgente; l'assenza di un arco non prova assenza di impatto.

Non dimostra correttezza numerica generale, ordine temporale, assenza di race,
gestione della memoria, prestazioni GPU, stampabilità fisica o stato dei file
esterni. Un controllo topologico di una mesh non sostituisce booleane,
rilevamento delle auto-intersezioni e verifica nello slicer.
