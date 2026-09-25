# Storico parametrico, parti e assiemi

Revisione 2 · requisito fondamentale · tutte le capacità di seguito sono da
implementare/verificare salvo una prova registrata nel task corrispondente.

## Storico come fondazione

Il documento conserva le operazioni che hanno costruito la geometria, i loro
parametri e i riferimenti alle operazioni precedenti. Edit, riordino compatibile,
soppressione e ritorno del marker sono il riferimento di interazione della
[timeline Fusion](https://help.autodesk.com/cloudhelp/ENU/Fusion-Designs/files/ASM-USE-TIMELINE.htm).

Tre concetti rimangono distinti:

| Concetto | Significato e persistenza |
|---|---|
| Storico parametrico | Definizioni delle operazioni e dipendenze: sempre salvate e ricostruibili |
| Undo/redo | Transazioni dell'utente: non sostituiscono lo storico; fusione legata a una sessione di editing |
| Revisioni del documento | Snapshot/versioni e recupero dei salvataggi: preservano una versione del progetto, non risolvono dipendenze geometriche |

| ID | Requisito | Criterio di accettazione |
|---|---|---|
| H01 | `FeatureID` stabile, tipo/versione operazione, parametri con unità, input/output, proprietario componente | Salvataggio e riapertura preservano identità e dipendenze, senza affidarsi all'indice nella lista |
| H02 | Grafo aciclico delle dipendenze e ordine di valutazione deterministico | Una modifica rigenera i discendenti interessati; cicli e riferimenti mancanti sono respinti con diagnosi |
| H03 | Parametri nominati, espressioni, unità e dimensioni fisiche | Una quota derivata segue la quota sorgente; formule invalide o cicliche non corrompono il design |
| H04 | Modifica, soppressione, riordino lecito e inserimento al marker | Riordinare una feature prima dei suoi input è vietato; soppressione non coincide con invisibilità |
| H05 | Rollback/roll-forward con coda delle feature conservata | Tornare indietro e poi in fondo ricostruisce lo stato; nessuna cancellazione silenziosa delle operazioni successive |
| H06 | Diagnostica per feature: valida, sporca, soppressa, bloccata da input, in errore | Un errore indica operazione e riferimento; l'ultima forma valida può essere mostrata solo come risultato precedente esplicito |
| H07 | Riferimenti a facce/spigoli robusti al rebuild | Cambiare una quota non ricollega un foro a una faccia casuale; riferimenti ambigui richiedono riparazione |
| H08 | Commit atomico, annullamento dei calcoli e controllo revisione | Un risultato tardivo non sostituisce una revisione più recente; un errore non salva metà operazione |
| H09 | Undo/redo di parametri, soppressioni, creazione, eliminazione e relazioni | Un gesto di editing è una transazione; annullare non lascia riferimenti orfani |
| H10 | Persistenza con schema e migrazioni testate | Lettura del formato iniziale `.ftk`, migrazione su copia e riapertura; versione futura non supportata produce errore esplicito |

La cronologia dell'import non va inventata: una forma importata senza feature
originali è una feature di import con provenienza, seguita dalle operazioni
create nell'app. Lo storico disponibile nel documento iniziale va preservato
alla migrazione per quanto effettivamente registrato.

## Parti, corpi e occorrenze

Un body è geometria; una definizione di parte possiede origine, schizzi, feature,
corpi e metadati. Un'occorrenza istanzia una definizione in un assieme con una
trasformazione propria. Più occorrenze possono riusare una stessa parte.
Questa separazione risponde ai flussi di [componenti](https://help.autodesk.com/cloudhelp/ENU/Fusion-Assemble/files/ASM-COMPONENTS.htm)
e [occorrenze](https://help.autodesk.com/cloudhelp/ENU/Fusion-360-API/files/fusion_Occurrence.htm)
del riferimento; i nomi dei nostri tipi restano da definire nel contratto API.

| ID | Requisito | Criterio di accettazione |
|---|---|---|
| P01 | Definizione parte, uno o più corpi, sistema locale e storico | Due corpi di una parte non vengono contati automaticamente come due articoli |
| P02 | Istanza condivisa e copia indipendente | La modifica della definizione aggiorna le istanze; rendere una copia indipendente interrompe quel legame esplicitamente |
| P03 | Schizzi quotati/vincolati e feature meccaniche | Estrusione, rivoluzione, fori, booleane, raccordi/smussi, guscio, pattern/specchio, sweep/loft entrano nello storico |
| P04 | Parametri, codici articolo, materiale, revisione e proprietà | Proprietà fisiche usano geometria e densità dichiarate; dati sconosciuti non diventano valori inventati |
| P05 | Parti interne/esterne e modifica in contesto | Un riferimento esterno ha documento/revisione espliciti; file mancante o dipendenza circolare non viene ignorato |
| P06 | Interoperabilità | STEP per geometria CAD; STL/3MF derivati per stampa. Un STL reimportato non recupera magicamente feature e vincoli originali |

## Assiemi e relazioni

| ID | Requisito | Criterio di accettazione |
|---|---|---|
| A01 | Gerarchia di occorrenze e sottoassiemi, contesto attivo e trasformazioni | Pose locale/globale corrette anche con rotazioni e sottoassiemi riutilizzati; gerarchie cicliche vietate |
| A02 | Fissaggio a terra, gruppi rigidi, joint origin | Una parte fissata resta immobile durante il solve; un gruppo conserva le trasformazioni relative |
| A03 | Giunti/vincoli: rigido, rotoidale, prismatico, cilindrico, pin-slot, planare e sferico | Ogni tipo conserva solo i gradi di libertà previsti; offset, limiti e orientamento sono persistenti |
| A04 | Risoluzione, DOF e sovravincolo | Relazioni incompatibili restituiscono diagnosi senza saltare a una posa arbitraria |
| A05 | Azionamento dei giunti e collegamenti di moto | Movimento e limiti sono riproducibili; anteprima cinematica distinta da una simulazione fisica |
| A06 | Aggiornamento dopo modifica parte | Le istanze e i giunti seguono la parte; riferimenti invalidati sono segnalati e riparabili |
| A07 | Interferenze, misure e distinta | Rilevare intersezioni volumetriche, trattare il contatto con tolleranza; distinta per occorrenze e codici, senza legarla alla sola visibilità |
| A08 | Salvataggio, export ed esploso documentale | Gerarchia, trasformazioni, revisioni, vincoli e riferimenti sopravvivono alla riapertura; l'esploso non altera la posa di progetto |

Le [relazioni d'assieme Fusion](https://help.autodesk.com/cloudhelp/ENU/Fusion-Assemble/files/ASM-JOINTS.htm)
comprendono vincoli e giunti. La nostra copertura va verificata per tipo e per
combinazione: un semplice spostamento dei triangoli non implementa un assieme.

## Modello di dominio proposto

```text
DesignDocument
  schemaVersion, documentID, revisionID, units
  parameterTable
  componentDefinitions [ComponentID → sketches, features, bodies, metadata]
  occurrences [OccurrenceID → ComponentID, parent, transform, revision reference]
  featureGraph [FeatureID → typed parameters, references, state, kernel result]
  assemblyRelationships [JointID → occurrence paths, references, limits]
  sheetMetalRules [RuleID → immutable rule revision]
  derivedArtifacts [flat patterns, tessellations, drawing/export revisions]
```

`BodyID`, `ComponentID`, `OccurrenceID`, `FeatureID`, `JointID` e riferimenti
topologici non sono intercambiabili. I risultati triangolati portano anche
`revisionID` e mappa triangolo → faccia CAD; la selezione persistente usa l'identità
di dominio. Il numero di triangolo da solo vale soltanto per quello snapshot.

La UI lavora su snapshot immutabili e comandi; il kernel lavora fuori dal thread
UI quando necessario. La pubblicazione del risultato torna al Model con una
verifica della revisione. Salvataggio e export usano una revisione coerente.

## Casi di accettazione prioritari

1. Base estrusa → foro riferito → raccordo: cambiare larghezza iniziale, rigenerare,
   salvare/riaprire e verificare dimensioni, riferimenti e ordine delle feature.
2. Sopprimere il foro, tornare al marker iniziale e ripristinare: stato dipendente
   esplicito e recupero senza cambiare gli ID.
3. Parte riutilizzata tre volte in due sottoassiemi: modificare la definizione,
   verificare tre aggiornamenti, quantità in distinta e trasformazioni globali.
4. Rendere una copia indipendente: due istanze seguono l'originale e una segue la copia.
5. Perno e staffa con giunto rotoidale e limiti: verificare DOF e sovravincolo;
   cambiare la staffa senza ricollegamenti geometrici silenziosi.
6. Fallimento del rebuild e calcolo annullato: documento precedente integro,
   diagnosi associata alla feature e nessun risultato obsoleto mostrato come attuale.
