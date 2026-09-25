# Requisiti CAD — revisione 3

25 settembre 2026 · richiesta diretta di Ross · coordinamento T24.

**La chat che sviluppa geometrie e i connettori Claude/ChatGPT hanno priorità principale.**
[Contratto assistente](AI_ASSISTANT.md): Claude cura UX e connettore Claude;
Codex strumenti geometrici, OpenAI e connettore ChatGPT.

**Lamiera completa, storico parametrico, progettazione di parti e assiemi sono
requisiti fondamentali del prodotto.** La precedente esclusione degli assiemi
dal perimetro non è più valida. Questa revisione definisce il lavoro richiesto;
non dichiara queste funzioni già implementate.

## Obiettivo e priorità

Realizzare in Xcode un CAD macOS per parti meccaniche, lamiera e assiemi,
con storico modificabile e output per stampa 3D e lavorazione della lamiera.
Il riferimento funzionale per lamiera e storico è Autodesk Fusion alla data
del 25 settembre 2026. La matrice va estesa quando viene identificata una
capacità mancante; «completo» richiede verifica di tutte le voci, non la sola
presenza di pulsanti o di una timeline visiva.

| Priorità | Fondazione | Cosa deve garantire |
|---|---|---|
| P0 · prima consegna | Chat e MCP | Un catalogo CAD comune, operazioni reali, revisioni, errori e annullamento; T47–T55 |
| P0 | Storico e dipendenze | Modifica di un'operazione precedente, rigenerazione, errori espliciti e persistenza |
| P0 | Parti e istanze | Separazione tra definizione della parte, corpi, occorrenze e assiemi |
| P0 | Kernel geometrico | Geometria e topologia adatte a pieghe, riferimenti stabili, STEP e sviluppi |
| P1 | Lamiera | Intero percorso regole → forma piegata → lavorazioni → sviluppo → esportazione |
| P1 | Assiemi | Sottoassiemi, posizionamento, giunti/vincoli, distinta e interferenze |
| P1 | Consegna | Documenti riapribili con storico; STL/3MF, STEP, DXF e documentazione di piega |

Le priorità stabiliscono l'ordine tecnico: non eliminano le funzioni delle fasi
successive dalla richiesta. CAM completo, nesting automatico, simulazione FEA,
cloud/PDM e slicing restano fuori da questa revisione; tavole e dati di produzione
della lamiera, distinta e assiemi sono invece inclusi.

## Responsabilità e contratto tra agenti

- **Codex:** kernel, dati, storico, ricostruzione, parti/istanze, giunti e solver,
  lamiera e sviluppi, persistenza/migrazioni, export, test e API del Model.
- **Claude:** ambienti Parti/Assiemi/Lamiera, browser gerarchico, timeline con
  marker e modifica delle feature, selezione, anteprime, regole e pannelli,
  presentazione degli errori e dei documenti di produzione.
- **Condiviso:** firme e stati delle API, criteri di accettazione e integrazione;
  task e claim rimangono in `docs/graph/tasks.json` tramite `scripts/graph.py`.

Le API geometriche costose potranno essere asincrone. L'interfaccia deve poter
mostrare avanzamento, annullare un calcolo e scartare un risultato di una revisione
superata; la proposta precedente «tutto sincrono su MainActor» non va applicata
al futuro kernel senza verifica.

## Decisione architetturale

Il core iniziale descrive primitive indipendenti e triangoli. Può continuare a
supportare il prototipo, ma non costituisce il modello geometrico definitivo
per questi requisiti. La mesh sarà una rappresentazione derivata per viewport,
stampa e controlli preliminari, separata da forme CAD e riferimenti topologici.

Serve un contratto `GeometryKernel` con forme opache e identità stabili, isolamento
degli errori e tolleranze esplicite. Open CASCADE è un candidato B-rep da verificare
con un prototipo macOS, gestione della memoria, distribuzione e casi geometrici;
nessuna libreria viene dichiarata scelta/installata da questo documento. Il kernel
da solo non fornisce automaticamente storico affidabile, solver assiemi o tutto
il modulo lamiera: sono sottosistemi da implementare e provare.

Le operazioni CSG su mesh del vecchio T08 possono essere ausiliarie. Non devono
diventare il vincolo architetturale che impedisce lamiera, STEP o riferimenti di
faccia persistenti. Eventuali cambi delle API passano dal registro condiviso.

## Documenti complementari

- [Assistente e MCP](AI_ASSISTANT.md): priorità, ruoli e criteri di esecuzione.
- [Storico, parti e assiemi](PARAMETRIC_ASSEMBLIES.md): modello di dominio,
  dipendenze, ricostruzione, documenti e casi di accettazione.
- [Lamiera](SHEET_METAL.md): matrice delle capacità, stati geometrici e test.
- [Grafo di progetto](DOMAIN_GRAPH.md): architettura **pianificata**, distinta
  dal grafo del sorgente effettivamente implementato.

Stato aggiornato e assegnazioni: [grafo dei task](../graph/GRAPH.md).
Scambi e decisioni: [registro progressivo](../COLLAB.md).

## Prova trasversale richiesta prima di dichiarare il percorso pronto

Creare una staffa in lamiera con una base, due pieghe e fori. Salvare e riaprire
il documento con lo storico integro. Modificare lo spessore e una quota iniziale,
ricostruire pieghe e fori, aggiornare lo sviluppo e i riferimenti d'assieme.
Inserire due istanze della staffa e un perno in un sottoassieme; vincolarle,
verificare quantità in distinta e distinguere interferenza da semplice contatto.
Esportare il piatto in DXF con linee di piega e il modello in STEP/STL/3MF.

La geometria CAD, l'import nei programmi destinatari e la verifica di un pezzo
realmente fabbricato sono prove distinte. Regole di piega e materiali usati nei
test sono fixture dichiarate; i parametri dell'officina non si deducono dal nome
del materiale.

## Evidenze e riferimenti

Le seguenti fonti definiscono il riferimento funzionale; le scelte del nostro
modello dati sono proposte progettuali, non una descrizione degli interni Autodesk.

- [Timeline Autodesk](https://help.autodesk.com/cloudhelp/ENU/Fusion-Designs/files/ASM-USE-TIMELINE.htm).
- [Componenti Autodesk](https://help.autodesk.com/cloudhelp/ENU/Fusion-Assemble/files/ASM-COMPONENTS.htm).
- [Relazioni d'assieme Autodesk](https://help.autodesk.com/cloudhelp/ENU/Fusion-Assemble/files/ASM-JOINTS.htm).
- [Kernel OCCT: modellazione e interscambio](https://occt3d.com/dev/doc/overview/html/index.html).

