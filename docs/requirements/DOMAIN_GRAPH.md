# Grafo del dominio — revisione 3

Fonte canonica: [domain-graph.json](domain-graph.json). Architettura richiesta, non call graph del codice.
Tutti gli archi sono INFERRED: nessuna risoluzione semantica o prova di funzionamento è implicita.
Lo stato operativo è nel [grafo task](../graph/GRAPH.md); accordi nel [registro](../COLLAB.md).

```mermaid
flowchart TB
  ux["UX Parti / Assiemi / Lamiera · Claude"]
  model["Model e comandi transazionali · Codex"]
  history["Storico e motore di ricostruzione · Codex"]
  params["Parametri, espressioni e unità · Codex"]
  sketch["Schizzi e vincoli · Codex"]
  kernel["GeometryKernel / B-rep · Codex"]
  topology["Riferimenti facce / spigoli · Codex"]
  parts["Definizioni di parti e corpi · Codex"]
  assembly["Occorrenze, assiemi e giunti · Codex"]
  sheet["Lamiera e regole di piega · Codex"]
  flat["Flat Pattern revisionato · Codex"]
  export["STEP / STL / 3MF / DXF / tavole · Codex + UX Claude"]
  store["Documento e migrazioni · Codex"]
  render["Mesh derivate e selection map · Codex dati / Claude rendering"]
  chat["Chat geometrica principale · Claude"]
  claude["Provider e connettore Claude · Claude"]
  openai["Provider OpenAI e ChatGPT MCP · Codex"]
  mcp["MCP locale e bridge privato · Condiviso"]
  tools["Catalogo CADToolProvider · Codex"]
  ux -->|"invoca comandi"| model
  model -->|"modifica e valuta"| history
  history -->|"valuta espressioni"| params
  history -->|"ricostruisce schizzi"| sketch
  history -->|"valuta operazioni geometriche"| kernel
  history -->|"risolve riferimenti"| topology
  parts -->|"possiede feature"| history
  assembly -->|"istanzia definizioni"| parts
  assembly -->|"riferisce geometria nei giunti"| topology
  sheet -->|"appartiene a un componente"| parts
  sheet -->|"calcola pieghe e forme"| kernel
  sheet -->|"registra operazioni"| history
  sheet -->|"genera derivato revisionato"| flat
  flat -->|"fornisce sagoma e pieghe"| export
  parts -->|"fornisce forme e mesh"| export
  kernel -->|"genera tessellazione"| render
  topology -->|"fornisce selection map"| render
  render -->|"visualizza snapshot"| ux
  store -->|"persiste feature e parametri"| history
  store -->|"persiste definizioni"| parts
  store -->|"persiste istanze e relazioni"| assembly
  store -->|"persiste provenienza e stato"| flat
  chat -->|"usa provider"| claude
  chat -->|"usa provider"| openai
  claude -->|"collega client esterno"| mcp
  openai -->|"collega ChatGPT esterno"| mcp
  chat -->|"invoca comandi locali"| tools
  mcp -->|"espone stessi strumenti"| tools
  tools -->|"valida e applica"| model
  tools -->|"registra operazioni future"| history
```

## Lettura del grafo

Chat, Claude e OpenAI condividono il catalogo di comandi e il Model.
Il percorso completo comprende storico, kernel, lamiera, parti e assiemi.
La vista e il JSON derivano dalla stessa descrizione; i riferimenti indicano requisiti, non sorgenti eseguibili.

## Confini di affidabilità

- Grafo dei contratti di progetto: anche dove esiste una v1 non prova la realizzazione completa. Stato implementazione nel grafo task.
- Nessun arco semanticamente risolto; nessuna prova numerica o runtime.
- Stato attività autorevole in docs/graph/tasks.json; non confondere done della specifica con done dell implementazione.
