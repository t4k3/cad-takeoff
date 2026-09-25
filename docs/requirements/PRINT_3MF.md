# Stampa 3MF a colori — T59 / T60

Richiesta Ross, 25 settembre 2026: esportare anche `.3mf` per definire i colori
delle parti. Destinazioni: **Bambu Studio, OrcaSlicer, Snapmaker Orca**.
Codex: modello, export, chat/MCP e prove. Claude: UX, colori nel viewport e menu.

## Contratto implementato

- `Feature.color: PartColor`: sRGB opaco a 8 bit, salvato nel documento `.ftk`.
  I documenti v1 senza colore vengono letti con il colore predefinito. Un vecchio
  programma che risalva un documento nuovo può perdere il campo colore.
- Una parte nominata per feature visibile, con ID stabile in `partnumber`, mesh
  separate e coordinate in millimetri, Z verso l'alto. Un componente contenitore
  mantiene le posizioni relative; nessuna fusione booleana implicita.
- 3MF Core + Materials Extension: un gruppo per colore, colore predefinito
  sull'oggetto, palette deduplicata. Colori uguali condividono la stessa voce.
- Profilo predefinito `bambuOrca`, utilizzabile anche con Snapmaker Orca: aggiunge
  `Metadata/model_settings.config` (nomi e indici colore delle parti) e
  `Metadata/project_settings.config` (solo `filament_colour`). Il profilo
  `.standard` omette questi metadati aggiuntivi.
- Nessun preset stampante, ricetta materiale/processo, G-code, assegnazione
  hardware AMS o utensile. L'indice `extruder` di compatibilità identifica una
  voce colore del progetto nello slicer, non una bobina o una testina fisica.
- Validazione prima dell'export: input geometrico nel Model; indici, coordinate
  finite, triangoli non degeneri, chiusura e orientamento dei bordi, volume
  positivo nell'esportatore. Questo non certifica assenza di auto-intersezioni,
  interferenze fra parti o stampabilità generale.
- Limiti prototipo: 256 parti, un milione di triangoli/vertici complessivi,
  XML principale fino a 64 MiB. Pacchetto ZIP senza compressione, CRC32 e
  central directory; nessuna dipendenza esterna o processo shell nell'app.

## Uso nello slicer

Aprire come **progetto 3MF** per caricare anche i colori. L'importazione della sola
geometria e alcune modalità CLI possono ignorare la palette. Scegliere il proprio
profilo stampante/materiale/processo, controllare la tabella parti/filamenti e
posizionare il modello sul piatto prima dello slicing. Il CAD conserva le
coordinate del progetto, quindi non centra automaticamente il modello sul piatto.

Il file contiene soltanto geometria e colori: non è un progetto già configurato
per una stampante. Alcuni slicer presentano comunque un avviso generico sui
preset quando vedono `project_settings.config`; il contenuto generato e verificato
da questo esportatore ha come unica chiave `filament_colour`.

## Assistente e storico

`set_color(feature_id, color: "#RRGGBB", expected_revision)` modifica una parte;
`color` è disponibile anche in `add_box`, `add_cylinder`, `add_extrude` e
`update_feature`. `get_feature` e `list_features` restituiscono il colore.
`export_3mf(feature_id?)` restituisce il pacchetto base64 (massimo 8 MiB per chat).
Senza ID esporta le parti visibili; con ID esporta quella parte anche se nascosta.

Ogni modifica colore è annullabile e ripetibile nella sessione, anche se eseguita
dal selettore UI mediante `DesignModel.setFeatureColor`. Il colore sopravvive al
salvataggio; **lo stack undo di sessione non è lo storico parametrico persistente**,
che resta nel percorso T29. Le altre modifiche manuali dirette ai Binding azzerano
ancora lo stack di sessione.

## Prove e limiti di evidenza

- `swift test --package-path Packages/CADCore`: round-trip colore e vecchi file,
  validazione colori/mesh, archivio deterministico e nomi XML.
- `scripts/test-3mf.sh`: genera `build/3mf/TwoColorParts.3mf`, due solidi a contatto
  (base rossa 40 × 30 × 5 mm e inserto blu 10 × 10 × 8 mm a Z=5), volume totale
  6800 mm³. Python legge ZIP/CRC, XML, palette, assegnazioni parti, topologia,
  dimensioni e posizioni indipendentemente dal produttore Swift.
- `scripts/test-assistant-tools.sh`: colore da chat/UI, errori atomici,
  undo/redo, file vecchi/nuovi, visibilità, 3MF read-only e nessun path arbitrario.
- `scripts/test-mcp-integration.sh`: assegnazione colore e 3MF attraverso un
  server HTTP locale reale con documento di prova isolato.
- Prova iniziale Bambu Studio 02.08.02.61 CLI: importazione e riesportazione,
  due parti, 24 triangoli, dimensioni 40 × 30 × 13 mm, volume 6800 mm³. Senza
  metadati perdeva nomi e associazioni; con metadati conserva i nomi e gli indici
  1/2 ma la modalità CLI usata conserva la sua palette predefinita verde.
- Prova GUI OrcaSlicer 2.3.2-dev: campione di compatibilità aperto come progetto,
  due colori rosso/blu e solidi corrispondenti visibili. Le prove CLI Orca e
  Snapmaker con configurazione vuota/minima hanno terminato con errore/crash:
  questo non costituisce verifica positiva di quei percorsi CLI.
- Snapmaker Orca GUI: importato il file finale `TwoColorParts.3mf`, base rossa e
  inserto blu visibili, palette 1/2; il pannello informazioni conferma
  40 × 30 × 13 mm, 6800 mm³, 24 triangoli. Bundle installato dichiara 2.3.5;
  il suo comando `--help` dichiara internamente 01.10.01.50 (non equiparati).
- Bambu GUI: verifica dei colori ancora da completare. La finestra esistente
  contiene un progetto utente modificato (`Mac Stand`), lasciato intatto; il
  tentativo di nuova finestra non ha fornito una superficie separata utilizzabile.

Perciò: importazione a colori osservata in Orca/Snapmaker; Bambu verificato via
CLI per geometria e indici delle parti, **non ancora per palette nella GUI**.

Nessuna stampa fisica o validazione di bobine/testine è inclusa in queste prove.
Parti/occorrenze del documento v2 verranno integrate in T10/T27; oggi la parte
esportabile coincide con una feature indipendente del prototipo.

## Riferimenti primari

- [3MF Core](https://github.com/3MFConsortium/spec_core/blob/master/3MF%20Core%20Specification.md)
- [3MF Materials Extension](https://github.com/3MFConsortium/spec_materials/blob/master/3MF%20Materials%20Extension.md)
- [Import/export Bambu Studio](https://github.com/bambulab/BambuStudio/blob/master/src/libslic3r/Format/bbs_3mf.cpp)
- [Import/export OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer/blob/main/src/libslic3r/Format/bbs_3mf.cpp)

I comportamenti dei binari installati prevalgono sulle aspettative ricavate dal
ramo di sviluppo dei sorgenti. Non viene dichiarata compatibilità universale
con ogni versione o modalità d'importazione.
