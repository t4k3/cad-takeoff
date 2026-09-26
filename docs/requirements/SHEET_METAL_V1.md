# Lamiera — integrata nell'app (T79–T80)

26 settembre 2026 · Claude. Sostituisce la prima base di Codex (T78: una piastra e una sola flangia, K a mano).

## Cosa fa

- **Elemento dello storico** come i solidi (`Feature.Kind.sheetMetal`): si crea dalla scheda **LAMIERA**, si modifica dalla timeline o dall'ispettore, si annulla con ⌘Z, si salva nel `.ftk`. Può creare un corpo nuovo o unirsi/tagliare come gli altri solidi; fori e raccordi funzionano sul piegato.
- **Piastra rettangolare + flange** su uno qualsiasi dei quattro lati (davanti −Y, destra +X, dietro +Y, sinistra −X): altezza, angolo 5–135° dalla posizione piana, verso su/giù, quota **esterna** (predefinita), interna o dalla tangente.
- **Ingombro esterno**: larghezza e profondità sono le linee di stampo esterne, come su un disegno d'officina. Una flangia a 90° con quota esterna 30 è alta 30 fuori tutto.
- **Pieghe vere**: nel piegato le pieghe sono superfici cilindriche (raggio interno e raggio + spessore) selezionabili e misurabili.
- **Sviluppo** (LAMIERA › Sviluppo): contorno piano con linee di piega (rosse in su, blu in giù) e tangenti; **DXF** in mm con layer `CUT`, `BEND_UP`, `BEND_DOWN`, `BEND_TANGENT` e i dati di piega nei commenti.
- **Fori nello sviluppo**: i fori fatti sul piegato (comando Foro) che attraversano la piastra o il tratto dritto di una flangia sono svolti nella posizione esatta e diventano cerchi `CUT` nel DXF e fori veri nella vista Sviluppo.
- **Altezze diverse per lato** nel pannello («Altezze diverse per lato»).
- **Assistente/MCP**: `add_sheet_metal` (materiale, spessore commerciale, ingombro, lati delle flange); la risposta riporta raggio, K, sviluppo e avvisi.

## Materiali e regole di piega

Valori tipici di **piegatura in aria** su pressa piegatrice con matrici V standard: un punto di partenza serio, non una taratura. La tabella del proprio piegatore vince sempre: raggio e K si possono impostare a mano.

| Materiale | Densità g/cm³ | Spessori commerciali mm | Raggio interno | Note |
|---|---|---|---|---|
| Acciaio DC01 (laminato a freddo) | 7,85 | 0,5–3 | ≈ 16% di V | lamiera da piega |
| Acciaio zincato DX51D+Z | 7,85 | 0,5–3 | ≈ 16% di V, ≥ t | lo zinco non deve criccare |
| Acciaio S235JR (a caldo) | 7,85 | 2–10 | ≈ 16% di V, ≥ t | carpenteria |
| Inox AISI 304 / 316 | 7,93 / 8,0 | 0,5–6 | ≈ 21% di V, ≥ t | più ritorno elastico |
| Alluminio 5754 H111 | 2,66 | 0,5–6 | ≈ 15% di V, ≥ t | la lega da piega |
| Alluminio 6082 T6 | 2,70 | 1–6 | ≥ 3t | duro: meglio 5754 se va piegato |
| Ottone CuZn37 | 8,44 | 0,5–3 | ≈ 14% di V | |
| Rame Cu-ETP | 8,94 | 0,5–3 | ≈ 13% di V | |

- **Matrice V**: circa 8·t fino a 3 mm, 10·t fino a 10 mm, 12·t oltre, arrotondata all'apertura standard più vicina (4, 6, 8, 10, 12, 16, 20, 24, 30, 35, 40, 50, 60, 80, 100, 120), mai sotto 6·t.
- **Raggio interno** = max(frazione di V del materiale, raggio minimo del materiale), arrotondato per eccesso al decimo.
- **K-factor** da **DIN 6935**: fattore di correzione k = 0,65 + 0,5·log10(r/t) (massimo 1), posizione della fibra neutra K = k/2 (limitato a 0,2–0,5).
- **Flangia minima** ≈ 0,7·V + t/2 (quota esterna a 90°): la flangia deve appoggiare su entrambe le spalle della matrice. Sotto questo valore l'app avvisa, non blocca.

Esempio: DC01 2 mm → V16, Ri 2,6 mm, K 0,353, flangia minima 12,5 mm.

## Calcolo

```text
θ = angolo dalla posizione piana
arretramento esterno  OSSB = tan(θ/2)·(Ri + t)
arretramento interno  ISSB = tan(θ/2)·Ri
tratto dritto = L − OSSB (quota esterna) | L − ISSB (interna) | L (dalla tangente)
sviluppo della piega  BA = θ·(Ri + K·t)
striscia sviluppata = BA + tratto dritto
```

La piastra piana va dalla linea di stampo esterna meno OSSB su ogni lato con flangia. Gli **angoli tra flange sono aperti**: ogni flangia copre il tratto piano del suo lato, così lo sviluppo (a croce) non si sovrappone mai e non servono scarichi.

**Angoli chiusi** (opzione «Angoli: Chiusi», scatole): tra flange a 90° piegate nello stesso verso, le pareti davanti/dietro proseguono oltre la piega fino alla faccia esterna della parete laterale (OSSB), le pareti laterali arrivano a un gioco (0,2 mm di default) dalla loro faccia interna (OSSB − t − gioco). Nello sviluppo le alette di prolungamento stanno sul tratto dritto delle strisce e dove le pieghe si incontrano resta uno scarico quadrato BA × BA. Gli angoli con flange di angolo o verso diversi restano aperti, con un avviso.

## Verifiche

- `swift test --package-path Packages/CADCore`: regole dei materiali (V, raggi, K DIN, flangia minima), piastra, staffa a L con quote esterne e volume esatto della sezione, vassoio a 4 flange, piega in giù, avvisi e rifiuti, foro sul piegato, salvataggio, DXF.
- `bash scripts/test-sheet-metal.sh`: salva e riapre un disegno, esporta STL/3MF/DXF e li verifica con Python **ricalcolando da zero** la regola di piega (V, Ri, K DIN 6935) e le quote.

## Limiti (prossimi passi)

- Scarico tondo negli angoli chiusi; angoli chiusi con flange non a 90°.
- Flange su flange (profili a Z, cassette chiuse), orli (hem), flange parziali, forme della piastra da schizzo.
- Fori che attraversano una piega, fori ciechi o obliqui: non riportati nello sviluppo (l'export lo dice). Asole e tagli da schizzo.
- Tavola di piega (sequenza, angoli, quote) e compensazione del ritorno elastico.
