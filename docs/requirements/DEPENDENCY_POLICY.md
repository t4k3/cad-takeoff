# Librerie nostre e dipendenze esterne

25 settembre 2026 · richiesta diretta di Ross · T71.

**Sviluppare il più possibile le nostre librerie e funzioni. Usare librerie
esterne soltanto se strettamente necessarie.** Questa precisazione sostituisce
la precedente proposta di valutare OpenCascade e distingue una preferenza forte
da un divieto assoluto di qualsiasi dipendenza futura.

## Decisione operativa

- Il motore geometrico sarà sviluppato nel nostro `CADCore`. OpenCascade/OCCT
  non è una dipendenza scelta e il relativo spike e l'integrazione (T26/T62)
  restano annullati. Il grafo conserva quei task per tracciabilità.
- Geometria, topologia, storico, modello di parti e assiemi, funzioni lamiera,
  strumenti dell'assistente e formati supportati avanzano come codice nostro,
  con contratti pubblici e verifiche progressivi.
- Claude cura UX, selezione e presentazione delle operazioni; Codex cura core,
  funzionalità, persistenza, API e test. I contratti comuni si concordano nel
  registro, prima di modificarli.
- L'ordine e gli stati restano quelli della [roadmap approvata](../ROADMAP.md).
  Il passo 1 consolida chat, connettori, colori/export e verifiche. Claude ha
  comunicato nel registro la richiesta di Ross di avanzare al passo 2 mentre
  rimanda le prove dal vivo: T70 è il kernel da iniziare, T72 la selezione UI
  in corso; prove del passo 1 e CI T13 restano da completare.

## Che cosa consideriamo una dipendenza

| Categoria | Regola |
|---|---|
| Librerie CAD e solver di terzi inclusi nel prodotto | Evitati per impostazione iniziale; solo eccezioni motivate |
| Framework e strumenti Apple: Foundation, SwiftUI, Metal, URLSession, Xcode, Swift | Base della piattaforma scelta; il core conserva il proprio isolamento dalla UI |
| Strumenti di sviluppo, per esempio XcodeGen | Distinti dalle librerie distribuite nell'app; dichiarare comunque ogni nuova necessità |
| Servizi Anthropic/OpenAI e protocollo MCP | Integrazioni richieste da Ross; non richiedono per principio un SDK di terzi |
| Specifiche di formati e protocolli | Implementare uno standard con codice nostro non implica importare una libreria esterna |

Verifica del 25/09: `Packages/CADCore/Package.swift` non dichiara dipendenze
esterne; `project.yml` collega il package locale `CADCore` e il nostro bridge
`ftk-mcp`. Questo riscontro riguarda i manifesti attuali, non certifica tutte le
dipendenze transitive degli strumenti installati sul Mac.

## Quando valutare un'eccezione

Una difficoltà prevista o la comodità di una libreria non dimostrano da sole
una stretta necessità. Prima di proporne l'inserimento, registrare in `COLLAB.md`:

1. La funzione richiesta e il limite concreto dell'implementazione nostra,
   con un caso riproducibile o un requisito di interoperabilità.
2. Le alternative considerate: codice nostro, funzionalità Apple, riduzione
   temporanea del perimetro; motivare perché non bastano.
3. Il beneficio verificabile, la parte di prodotto interessata e i costi di
   manutenzione, distribuzione e licenza della dipendenza.
4. Una proposta circoscritta da concordare con Ross prima dell'integrazione,
   con interfaccia isolata e prove di accettazione.

Non è attualmente scelta alcuna eccezione per il kernel CAD.

## Criteri per il motore nostro

La prima tappa è una rappresentazione topologica di solidi a facce piane.
Robustezza, riferimenti di facce/spigoli dopo modifiche e gestione degli errori
sono risultati da provare con casi geometrici, non proprietà garantite dal nome
«B-rep». Dopo divisione o fusione di facce servono regole esplicite di rimappatura.

Curve e superfici sfaccettate sono approssimazioni. Metadati come asse e raggio
non le trasformano in superfici analitiche esatte. Una tolleranza proposta,
compresa quella di 0,01 mm nel registro, va verificata sui casi supportati prima
di diventare un impegno di precisione. La mesh per viewport e stampa resta una
rappresentazione derivata; accuratezza della forma e importazione nello slicer
richiedono verifiche distinte.

Storico persistente, parti/assiemi e lamiera restano requisiti fondamentali.
Ogni passo dichiara funzioni implementate, limiti e prove; la scelta di un motore
nostro non equivale ad avere già tutte le capacità di Fusion.
