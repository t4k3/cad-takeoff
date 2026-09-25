# Contratto fondativo UX / Core — T24

Revisione 2 · concordato nel registro con Claude il 25 settembre 2026.
**Contratto progettuale: firme e tipi seguenti non sono API già disponibili.**
La distinzione tra funzionalità disponibile e mock va mantenuta nella UI.

## Identità e selezione

- `DocumentID` e `RevisionID` identificano uno snapshot coerente.
- `ComponentID` identifica una definizione; `OccurrenceID` + percorso identificano
  l'istanza nel contesto dell'assieme; `BodyID` identifica il corpo.
- `FeatureID`, `SketchID`, `SketchEntityID`, `ConstraintID`, `ParameterID`,
  `FaceID`, `EdgeID`, `JointID` sono identità stabili di categorie distinte.
- Una selezione geometrica contiene contesto d'istanza, corpo, tipo topologico,
  riferimento persistente e revisione osservata. Gli ID non sono offset dei buffer.
- Codex fornisce snapshot per il renderer con mappa triangolo → faccia,
  polilinee di bordo con `EdgeID`, vertici notevoli e versione della geometria.
  Claude usa gli snapshot per selezione/evidenziazione, senza creare riferimenti CAD
  persistenti a partire dal solo indice triangolo.

## Schema dei parametri

Il Core descrive parametri tipizzati: identificatore, etichetta, dimensione/unità,
valore o espressione, limiti, valori ammessi, riferimenti geometrici richiesti,
stato modificabile/derivato e diagnostica. UI e Core distinguono almeno lunghezza,
angolo, numero adimensionale, intero, booleano, enumerazione e riferimento.

Claude adatta il proprio `CommandField` a questo schema. Il Core valida unità,
espressioni e riferimenti anche quando una UI invia un dato malformato; i limiti
della sola TextField non sono una validazione del documento. Icone, layout e
testi di presentazione appartengono alla UX; tipi e semantica al Core.

## Sessione di comando e ricostruzione

```text
beginEdit(featureID, expectedRevision) → EditSession
preview(sessionID, changes) → risultato revisionato / progresso / diagnostica
commitEdit(sessionID) → nuova revisione del documento
cancelEdit(sessionID) → ripristino dello stato precedente alla sessione
```

Anteprima e commit non condividono uno stato mutabile visibile a metà. La sessione
delimita anche l'unità di undo, senza fondere due gesti distinti solo perché vicini
nel tempo. Ogni comando verifica la revisione di partenza; i risultati asincroni
obsoleti sono scartati. Obiettivo UX proposto: anteprima entro 100 ms su un campione
semplice dichiarato; è un budget da misurare, non una prestazione già raggiunta.

I calcoli più lunghi forniscono `isRegenerating`, progresso se misurabile e
annullamento. Le modifiche si pubblicano in modo atomico sul Model/MainActor.
Un errore identifica la feature e gli input che lo causano; l'errore non annulla
silenziosamente l'intero documento né rende valido un risultato precedente.

## Timeline

Snapshot: ID, tipo, nome, componente proprietario, genitori/figli, parametri e
stato (`valid`, `warning`, `error`, `suppressed`, `beyondRollback`, `dirty`).

Comandi da esporre: marker/rollback, edit session, suppress/unsuppress,
verifica e applicazione del riordino, gruppi, navigazione alle dipendenze.
I nomi proposti da Claude (`moveRollback`, `canMove`, `move`, `group`) verranno
congelati insieme all'API implementata. Il riordino non cambia gli ID e non
viola l'ordine del grafo. Tutte le modifiche allo storico sono annullabili.

## Schizzi: contratto per T15/T05

Il documento conserva uno schizzo tramite `SketchID`, componente, piano locale
e riferimenti di supporto. Il piano è definito da origine e base ortonormale;
una faccia di supporto usa un riferimento stabile e un offset esplicito.

| Entità | Modello richiesto |
|---|---|
| Punto, segmento | ID propri e coordinate 2D nel piano, in mm |
| Cerchio, arco | Centro, raggio e parametri angolari; raggio positivo |
| Polilinea/rettangolo | Comando di creazione di entità e vincoli, non mesh persistente |
| Geometria di costruzione | Flag che la esclude dai contorni da estrudere |
| Vincoli | Coincidente, orizzontale/verticale, parallelo/perpendicolare, tangente, uguale, concentrico, simmetria, fissaggio |
| Quote | Distanza/lunghezza, diametro/raggio, angolo; guidanti o di riferimento |

Risultato del solver: coordinate risolte, DOF residui, vincoli incompatibili e
messaggi associati agli ID. Sottovincolato non equivale a invalido. Il solver non
deve spostare punti arbitrariamente senza una soluzione riproducibile.

I profili estrudibili sono derivati dallo schizzo: loop esterno e fori, orientamento,
chiusura, assenza di auto-intersezioni e riferimenti alle entità che li compongono.
Un profilo aperto rimane valido per contorno/sweep, ma non diventa automaticamente
una regione chiusa. La precedente `Profile2D` è un DTO del prototipo, non l'intero
modello persistente dello schizzo.

Claude può costruire la UX con mock confinati a `UI/Previews`; completare T05
richiede l'integrazione con il modello T15 e test del flusso, non il solo mock.

## Assiemi e lamiera

Il browser mostra componenti, corpi, schizzi, origine, occorrenze e giunti.
Attivare un componente cambia il contesto di editing; ghosting e camera sono UX.
Il Core espone trasformazioni, grounding, tipi di giunto, DOF, limiti e comandi
di movimento. I report di interferenza identificano coppie di occorrenze/corpi,
revisioni e misura geometrica con tolleranza.

La lamiera espone regole con lo stesso schema parametri e comandi che ricevono
riferimenti topologici. Lo sviluppo offre geometria piatta e linee di piega con
angolo/direzione, **più** legame alla revisione sorgente, stato e operazioni proprie.
Essere in vista piatta non prova di avere un Flat Pattern aggiornato. DXF e dati
delle tavole provengono dal Core; pannelli, anteprime e dialog appartengono a Claude.

## Gestione del cambiamento

Prima di introdurre o cambiare una firma: voce DECISIONE/RICHIESTA-API nel registro,
claim del relativo task e aggiornamento del contratto con stato proposto/implementato.
Il produttore fornisce test e versione; il consumatore conferma integrazione.
I moduli sperimentali del kernel restano isolati finché lo spike non ha dato una
decisione motivata. Non serve far attendere la specifica T24 alla compilazione
di una nuova dipendenza: il gate tecnico è un task successivo esplicito.
