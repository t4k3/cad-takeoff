# Classi di rete e aree vietate — contratto T94

Questa seconda tranche estende [PCB.md](PCB.md). API compilanti e 107 test del motore
verdi, inclusi 19 nuovi casi sulle regole. Lettore Python indipendente e fixture
esportata verificati. Integrazione T97 di Claude e collaudo nell'app completati per
classi, anteprima, aree, blocco del rame vietato e storico: [VALIDATION.md](VALIDATION.md).

## Classi

`PCBCopper.netClasses: [PCBNetClass]`, vuoto nei vecchi file.
`PCBNetClass(id:name:netIDs:constraints:routing:)` contiene una lista di reti esplicite,
`PCBNetClassConstraints` con minimi opzionali (`clearance`, `minimumTrackWidth`,
`minimumDrill`, `minimumAnnularRing`) e `PCBRoutingDimensions(trackWidth:viaDiameter:viaDrill:)`.
Una rete può appartenere a una sola classe. ID e nomi di classe sono univoci.

`ElectronicsPCB.resolvedRules(design:netID:) throws -> PCBResolvedNetRules` restituisce
`classID`, `className`, `rules: PCBDesignRules` e `routing: PCBRoutingDimensions`.
I minimi effettivi sono il massimo fra scheda e classe; la distanza fra due reti è
il massimo delle rispettive clearance. Il bordo resta una regola della scheda.
Dimensioni di routing e minimi DRC sono separati: le prime sono proposte, i secondi
obblighi. Le proposte sono alzate ai minimi effettivi (incluso anello anulare), senza
modificare di nascosto i dati salvati. La UI mostra i valori risolti.

Comandi `PCBCommand`: `addNetClass`, `updateNetClass`, `removeNetClass(UUID)`,
`assignNetClass(netIDs:classID:)` (nil ritorna alle regole globali). Assegnare sposta
esplicitamente le reti dalla classe precedente; eliminare una classe ripristina
le regole globali. Cambiare classe/regole non ridimensiona il rame già presente:
mostra le violazioni e permette di correggerle.
La risoluzione completa valida il documento: chiamarla al cambio di rete/revisione,
non a ogni movimento del cursore. Le dimensioni ottenute sono valori per la sessione
di routing; un aggiornamento di revisione invalida la sessione/anteprima come già per le piste.
Per la tabella completa usare `ElectronicsPCB.resolvedRules(design:) -> [UUID: PCBResolvedNetRules]`:
valida una volta e risolve tutte le reti in un worker cancellabile. Conservare la mappa
per identità/revisione; non chiamare l'overload singolo per ogni riga a ogni ridisegno.

Separare gruppi di fili di una rete automatica conserva la classe sui gruppi derivati.
Unire reti appartenenti a classi diverse produce `schematic_net_class_conflict`:
assegnare prima una classe comune. I riferimenti di classe conservano le reti automatiche
anche dopo rimozione dei fili; eliminare esplicitamente una rete senza rame rimuove
anche la sua assegnazione. Non si deducono classi per fili nuovi privi di origine/assegnazione.

## Aree vietate

`PCBCopper.keepouts: [PCBKeepout]`, vuoto nei vecchi file.
`PCBKeepout(id:name:outline:layers:tracks:vias:pads:zones:)`: poligono semplice in mm,
anche concavo, senza punto finale duplicato; strati espliciti; quattro esclusioni
indipendenti, almeno una attiva. Vietano il rame anche della stessa rete.
Il perimetro è incluso: il contatto col bordo dell'area è una violazione.
L'area può superare il contorno della scheda. Nessun margine extra implicito:
il contorno disegnato rappresenta il limite effettivo.

Comandi `addKeepout`, `updateKeepout`, `removeKeepout(UUID)`,
`moveKeepout(id:offset:)`; tutti annullabili e raggruppabili in un batch.
L'aggiunta/modifica di una regola sopra rame esistente è consentita e produce DRC;
aggiungere/modificare piste o via nell'area è rifiutato da `apply`.
Spostamenti dei componenti restano diagnosticati, senza impedirne la riparazione.

`PCBSnapshot.keepouts` fornisce i poligoni con ID e strati esatti da renderizzare.
`pickKeepouts(point:tolerance:layer:)` restituisce hit con `id`, `position`, `distance`;
`keepoutSnapTargets(near:radius:layer:)` fornisce vertici e proiezioni sui bordi.
Indice spaziale dedicato, nessuna area fittizia fra le primitive di rame.
`ElectronicsPCB.keepoutRectangle(from:to:)` costruisce il contorno rettangolare
oppure nil se degenere. La UI sceglie colore/tratteggio, non ricalcola il DRC.

Diagnostica `pcb_keepout`: ID dell'oggetto e dell'area, nome italiano dell'area,
posizione sul conflitto. Filtri per strato e tipo rispettati anche per pad/via passanti.
Un'area interamente nel foro vuoto non collide con l'anello di rame.

## Persistenza e prove

Classi e aree introdotte nel formato **5**; il formato corrente **6** legge 1–6 e conserva
l'intera catena Annulla/Ripeti. `zones` vale true anche nelle aree dei file precedenti:
la terza tranche [PCB_ZONES.md](PCB_ZONES.md) aggiunge il divieto indipendente per i piani.
Un vecchio lettore deve rifiutare il nuovo formato per non perdere le regole.
Stesse API per UI, assistente e MCP. Snapshot in background e cache per identità/revisione.

Riferimento funzionale studiato: [KiCad 9, aree di regola e classi](https://docs.kicad.org/9.0/en/pcbnew/pcbnew.html#rule-areas).
Implementazione propria; nessun sorgente o libreria KiCad incorporato.
I piani a collegamento pieno sono descritti in [PCB_ZONES.md](PCB_ZONES.md).
Non comprende classi multiple/priorità, pattern sui nomi delle reti,
impedenza, regole elettriche di sicurezza, Gerber o qualificazione produttiva.
