# Superfici esatte come verità del motore — piano a tappe

27/09/2026. Decisione di Ross: «superfici esatte è fondamentale». Obiettivo: il pezzo è fatto di
piani, cilindri, coni, sfere e tori **esatti**; triangoli e spigoli a segmenti sono solo una
*vista* del pezzo, calcolata alla risoluzione che serve (schermo, STL per la stampa, tavola).

## Com'è oggi (mappa del 27/09)

- Il motore è **a facce piane**: ogni cilindro è un prisma a 64 lati, ogni arco dello schizzo una
  spezzata a 64 lati per giro, i raccordi 64 passi per giro, le pieghe della lamiera 16 per 90°.
  Il numero è scritto in molti punti (`PrimitiveKernel`, `Revolve`, `Hole`, `Chamfer`,
  `SketchShape.arcSegments`, `Operations`, `SheetMetal`).
- Ogni faccia porta con sé la **superficie da cui viene** (`SurfaceDescriptor`: piano, cilindro,
  cono, toro, sfera, libera) e la conserva attraverso le booleane: così STEP esce esatto, i
  raccordi sanno su che superfici lavorano, lo schizzo su faccia trova il piano.
- Le booleane lavorano sui **poligoni** (`CSGMesh`, ricaduta BSP): esatte per i piani, per il
  resto sono esatte sulla sfaccettatura, non sulla superficie vera.
- Gli **identificativi** delle facce che i disegni salvano (smussi e raccordi `EdgeRef`, gusci,
  «fino a faccia») sono stabili per pareti e bordi dei cilindri e per gli archi delle estrusioni
  con chiavi di schizzo; invece contengono il numero di segmenti o la posizione dei punti per le
  estrusioni senza chiavi (`extrude/<punti>`), per le facce di rivoluzione (`side/<i>`) e per
  tutta la topologia interna (`…/cylinder/64/…`).
- Il profilo di un'estrusione è **salvato già spezzato** (`Profile2D` di punti): gli archi si
  ritrovano dopo, per adattamento di cerchi ai vertici.
- Chi legge la geometria sfaccettata: STEP (rifà i cerchi dai vertici), tavola (cerca i cerchi
  nei contorni), giunti (cerchio dai punti di uno spigolo), fori (centro = media dei punti),
  Premi/Tira (copia il contorno sfaccettato in un profilo nuovo).
- Molti test hanno volumi e aree calcolati sul 64-gono.

## Tappe

Ogni tappa lascia l'app funzionante, con test, CI verde e i disegni salvati che si riaprono
uguali. Nessuna tappa cambia i file `.ftk` in modo che una versione vecchia li legga male
(formato del documento aumentato quando serve).

### Tappa 1 — Risoluzione come parametro, identità che non ne dipendono

**Stato 27/09: completata.** Fatti i punti 2, 4 e 5 — `Tessellation.factor` moltiplica ogni conteggio del
motore (cilindri, fori, raccordi e sfere d'angolo, rivoluzioni, pieghe) e gli archi dei profili
si tagliano più fini sul loro cerchio; nomi di facce e spigoli identici a ogni risoluzione, pezzi
chiusi (test `TessellationTests`); export STL/3MF «Fine» (256 lati per giro) predefinito, anche
dall'assistente (`quality`). Punti 1 e 3 non necessari: gli archi dei profili si riconoscono esatti
dai punti (e dalle chiavi dello schizzo), e i nomi restano quelli del profilo disegnato a ogni
risoluzione — un profilo cambiato li invalida di proposito, invece di legarli alla faccia sbagliata.

1. **Profili con le curve vere.** `Profile2D` conserva, accanto ai punti, i tratti di arco e
   cerchio da cui vengono (centro, raggio, verso). Lo schizzo li scrive; i file vecchi senza
   curve continuano col riconoscimento degli archi di oggi.
2. **Una sola politica di sfaccettatura** (`Tessellation`): tolleranza di corda e angolo massimo,
   da cui il numero di segmenti per ogni cerchio in base al suo raggio. Sostituisce tutti i 64,
   48 e 16 scritti a mano. Valore interattivo = quello di oggi (nessun cambiamento visibile).
3. **Identità indipendenti dai segmenti**: niente numero di segmenti né coordinate dei punti
   nelle facce e negli spigoli che i disegni salvano; le facce di rivoluzione chiamate dal
   tratto di profilo (come le estrusioni). Migrazione dei nomi vecchi nei disegni salvati.
4. **Export più liscio**: STL e 3MF ricalcolati a tolleranza fine (es. 0,01 mm) solo per
   l'export, senza toccare i riferimenti; scelta «Normale / Fine» nel pannello di export.
5. La cache delle valutazioni include la risoluzione.

*Accettazione:* un disegno vecchio con smussi e raccordi si apre identico; un Ø100 esportato
«Fine» ha scostamento ≤ 0,01 mm; cambiare la risoluzione non cambia nessun `FaceID` salvato.

### Tappa 2 — Spigoli e vertici esatti

**Stato 27/09:** ogni spigolo porta la sua curva vera quando le due superfici la descrivono
(`EdgeCurve`: rette tra piani e lungo i cilindri; cerchi tra piano e cilindro, cono, sfera o toro,
e tra cilindro e toro o sfera coassiali — i raccordi sui bordi dei fori), verificata sui vertici
della sfaccettatura e spostata con le copie. La tavola prende i cerchi (centri e diametri) dagli
spigoli. Da fare: intersezioni non circolari (ellissi, cilindro–cilindro) e i vertici esatti nei
risultati delle booleane (tappa 3).

Ogni spigolo porta la sua curva vera (retta, cerchio, ellisse, curva di intersezione) calcolata
dalle due superfici, e i vertici i loro punti esatti. Ne approfittano: STEP (niente più cerchi
rifatti dai vertici), tavola (cerchi e centri esatti), giunti e fori (centri e assi esatti),
Premi/Tira (profili con archi veri).

*Accettazione:* STEP di un pezzo con fori e raccordi senza nessuna faccia sfaccettata; centri dei
fori esatti a 1e-9.

### Tappa 3 — Booleane sulle superfici

Intersezione faccia–faccia analitica dove esiste in forma chiusa (piano con piano, cilindro,
cono, sfera, toro; cilindri coassiali o paralleli), numerica con tolleranza per le altre coppie
(cilindro–cilindro sghembi…); facce tagliate descritte dalla superficie e dai loro bordi, poi
sfaccettate. Le booleane a poligoni di oggi restano la **riserva** per i casi non coperti, con
un avviso.

*Accettazione:* volume di un cilindro forato trasversalmente esatto a 1e-6 relativo a qualunque
risoluzione; STEP tutto esatto per i pezzi di prova del RobotVolley.

### Tappa 4 — Raccordi, smussi e gusci sulle superfici vere

Raccordo a sfera rotolante sulle coppie analitiche (piano–piano, piano–cilindro, cilindro–
cilindro coassiale), smusso per distanze sulle superfici, guscio per superfici offset.

### Tappa 5 — Vista a risoluzione di schermo

Il viewport chiede la sfaccettatura in base allo zoom (cerchi lisci da vicino), in background,
senza rivalutare la cronologia.

## Rischi

- Le booleane esatte (tappa 3) sono il pezzo più lungo e delicato: tolleranze, casi tangenti,
  facce che si toccano. Per questo restano le booleane di oggi come riserva, caso per caso.
- Ogni cambiamento di nomi di faccia richiede la migrazione dei disegni salvati: è la prima
  cosa che si prova in ogni tappa.
- Due errori già visti nella mappa, da correggere lungo la strada: il guscio di un foro riduce
  il raggio invece di aumentarlo (`Shell.swift:79`); in una rivoluzione un arco centrato
  sull'asse diventa un toro di raggio nullo invece di una sfera (e STEP lo scarta).
