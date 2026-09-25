# Lamiera — copertura funzionale richiesta

Revisione 2 · 25 settembre 2026 · requisito Ross: «tutta la parte lamiera di Fusion 360».
Stato iniziale di ogni voce: **richiesta, non ancora implementata/verificata**.

La copertura viene verificata per capacità e casi geometrici, non per somiglianza
dell'interfaccia. Le forme avanzate mantengono una voce propria: non vengono
eliminate dal requisito perché successive al primo campione funzionante.

## Matrice funzionale

| ID | Capacità richiesta | Dati/comportamento atteso | Verifica minima |
|---|---|---|---|
| SM01 | Componenti lamiera e libreria regole | Spessore, materiale, raggio interno, K-factor, gap, scarichi, revisione regola e override locali | Una modifica di regola rigenera la parte e invalida lo sviluppo precedente |
| SM02 | Flangia base | Profilo chiuso, spessore uniforme e orientamento | Sagoma non rettangolare con aperture, facce e spessore coerenti |
| SM03 | Flange di bordo | Lunghezza, angolo, posizione della piega, estensione parziale, bordi multipli e miter | Staffa L/U e scatolato aperto, con riferimenti che sopravvivono al cambio quote |
| SM04 | Flangia di contorno | Profilo aperto con più tratti/pieghe e larghezza | Sezione multipiega, raggi e lunghezze coerenti con regola e quote |
| SM05 | Piega da linea e Join by Bend | Faccia fissa, linea/asse, direzione, angolo, collegamento di corpi compatibili | Piega su piastra e collegamento con singola piega; casi impossibili respinti |
| SM06 | Bordi ripiegati / Hem | Varianti del riferimento: ripieghe e giochi con raggio, ritorno e orientamento | Più varianti testate, spessore costante e sviluppo coerente |
| SM07 | Flange lofted e transizioni | Profili, corrispondenze e modalità sviluppabile/faccettata definite | Transizioni campione; geometria non sviluppabile segnalata senza inventare uno sviluppo esatto |
| SM08 | Rip, aperture, cuciture e gap | Taglio/apertura di anelli o corpi convertiti, regole locali | Parte chiusa resa sviluppabile mediante apertura esplicita |
| SM09 | Scarichi e chiusure degli angoli | Scarichi di piega e angoli a 2/3 pieghe, miter, chiusura/overlap e override | Scatola con angoli interferenti: geometria di taglio conforme alle impostazioni |
| SM10 | Lavorazioni della lamiera | Fori, asole, tagli, pattern/specchio, raccordi/smussi specifici compatibili con spessore | Lavorazioni sulle flange e a cavallo di una piega, con riferimento nello storico |
| SM11 | Converti in lamiera | Corpi CAD/importati compatibili, spessore e riconoscimento verificati | Import di parte a spessore costante; fallimento esplicito su spessori variabili o geometria incompatibile |
| SM12 | Unfold / Refold | Stato di lavoro temporaneamente spiegato con faccia fissa e pieghe selezionate | Spiegare, creare un'asola attraverso la piega, ripiegare e rigenerare dallo storico |
| SM13 | Sviluppo piano / Flat Pattern | Derivato di produzione associato alla revisione della parte e a una faccia fissa | Sagoma, aperture, linee/zone di piega e orientamento coerenti; stato da aggiornare dopo modifica |
| SM14 | Edit di produzione sullo sviluppo | Operazioni proprie del derivato, con provenienza e storico separati | Modifica solo sul piatto non altera silenziosamente il modello piegato |
| SM15 | DXF e documenti di piega | Contorni, fori, layer separati per pieghe su/giù, unità, angoli, raggi, note e identificazione parte | File riaperto in un lettore indipendente, quote e layer verificati; tavola piegato + piatto |
| SM16 | Controlli geometrici e di produzione | Auto-intersezioni, collisioni tra flange, spessore, gap e parametri mancanti | Errori bloccanti distinti dagli avvisi; nessun export dichiarato valido con sviluppo obsoleto |
| SM17 | Integrazione con storico e assiemi | PartID/OccurrenceID, feature dipendenti, aggiornamento istanze e distinta | Cambiare la regola di una parte riutilizzata aggiorna tutte le istanze e i derivati interessati |

L'inventario di flange include base, bordo, contorno, hem e lofted nel riferimento
[Autodesk Flanges](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-FLANGES.htm).
Le opzioni numeriche di regole e scarichi si verificano con la
[documentazione delle regole](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-RULES-REF.htm).
Convertire un corpo e applicare regole richiede un flusso dedicato:
[componenti lamiera](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-COMPONENTS.htm).

La baseline comprende anche le capacità pubblicate nel settembre 2026:
Join by Bend, raccordi/smussi specifici lamiera e Corner Closure Overlap.
[Aggiornamento ufficiale Autodesk](https://www.autodesk.com/products/fusion-360/blog/september-2026-major-product-update-whats-new/).
Per Hem la verifica dettagliata comprende le varianti e i relativi parametri,
non soltanto una piega a 180°: [riferimento Hem](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-REF-HEM-FLANGE.htm).

## Stati geometrici distinti

| Stato | Scopo | Effetto delle modifiche |
|---|---|---|
| Modello piegato | Parte progettata, feature e geometria 3D | Alimenta istanze d'assieme, viste e sviluppo |
| Unfold nel design | Lavorare temporaneamente su pieghe/flange spiegate | Le lavorazioni sono nello storico e tornano nel modello con Refold |
| Flat Pattern | Derivato per taglio e documentazione | Segue una revisione del modello; modifiche locali allo sviluppo non riscrivono il piegato |

Questa separazione riprende il comportamento documentato di
[Unfold/Refold](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-UNFOLD-IN-SM.htm)
e [Flat Pattern](https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/GUID-121F6E58-0459-4552-85EF-319F44324AE6.htm).
Nel nostro documento ogni derivato deve conservare `sourceRevisionID`,
`ruleRevisionID`, faccia fissa e stato aggiornato/obsoleto/errore.

## Regole geometriche e dati dell'officina

- Coordinate e dimensioni in mm; angoli con unità esplicita e convenzione
  dichiarata (angolo di piega e angolo interno non sono intercambiabili).
- Spessore positivo uniforme nel perimetro supportato; raggio interno, gap,
  scarichi e tolleranze espliciti. Non correggere valori invalidi silenziosamente.
- K-factor e tabelle di allowance/deduction sono modelli di calcolo versionati;
  usare le tabelle reali dell'officina quando disponibili. Un materiale con lo
  stesso nome può richiedere regole diverse per utensile/processo.
- La linea neutra e la lunghezza sviluppata appartengono al calcolo geometrico;
  lo springback e l'angolo da impostare sulla macchina non si deducono automaticamente
  dalla sola forma CAD. Il dato richiesto dal processo va distinto dal nominale.
- Le forme non sviluppabili o oltre la copertura verificata non devono produrre
  un DXF presentato come esatto. Modalità approssimate/faccettate richiedono una
  tolleranza e un'indicazione esplicite.
- Gli scarichi finali del piatto vengono calcolati con le regole di produzione;
  non appiattire semplicemente i triangoli visualizzati.

## Corpus di accettazione

| Campione | Scopo |
|---|---|
| Lamiera piana con foro e asola | Conservazione spessore, contorni e unità DXF |
| Staffa L a 90° e staffa U | Direzioni, raggi e lunghezze sviluppate su fixture analitica/calibrata |
| Scatola aperta a quattro flange | Scarichi a 2/3 pieghe, miter, chiusure e collisioni |
| Profilo di contorno multipiega | Rigenerazione dopo modifica di un segmento iniziale |
| Asola attraverso la piega | Unfold → lavorazione → Refold e replay dello storico |
| Hem e transizione lofted | Copertura delle varianti, limiti geometrici dichiarati |
| Corpo CAD importato con Rip | Conversione, apertura e sviluppo; rigetto del caso incompatibile |
| Parte riutilizzata nell'assieme | Modifica spessore/regola, aggiornamento istanze e invalidazione derivati |
| Documento riaperto dopo errore | Nessuna perdita delle feature; recupero dell'ultima revisione valida |

Per ogni fixture registrare parametri, regola e tolleranze, risultato atteso,
risultato misurato e versione del kernel. Confronto geometrico, round-trip dei
formati, validazione UX e campione fabbricato sono livelli di prova separati.

## Chiusura del requisito «lamiera completa»

Ogni voce SM01–SM17 deve avere task funzionale, task UX, test di accettazione e
stato dimostrabile. Le opzioni scoperte durante l'uso dei comandi del riferimento
vengono aggiunte alla matrice. Non dichiarare equivalenza integrale a Fusion
finché la matrice e il corpus concordati non sono chiusi; il primo pezzo piegato
e sviluppato è un traguardo intermedio, non la conclusione del modulo.
