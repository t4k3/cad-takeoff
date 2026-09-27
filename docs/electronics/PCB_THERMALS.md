# Termiche e larghezza del rame — contratto T94

27/09/2026, quarto traguardo. API congelate dopo i test del core; aggancio T97 e collaudo UI in corso.
Implementazione Swift propria, nessuna libreria geometrica esterna. Questo contratto estende
[PCB_ZONES.md](PCB_ZONES.md), mantenendo gli stessi comandi e le stesse identità.

## Parametri del piano

Nuovi campi mutabili di `PCBZone`, presenti anche nell'inizializzatore con valori predefiniti:

| Campo | Valore iniziale/legacy | Significato |
|---|---|---|
| `connection: PCBZoneConnection` | `.solid` | `.solid` pieno; `.thermal` termiche SMD e passanti; `.thermalThroughHole` termiche solo passanti, SMD pieni; `.none` isolamento delle piazzole. |
| `thermalGap: Double` | 0.3 mm | Spazio fra piazzola e piano, interrotto dai ponticelli nelle modalità termiche. Positivo. |
| `thermalSpokeWidth: Double` | 0.3 mm | Larghezza nominale dei quattro ponticelli. Positiva; controllata rispetto a classe e minimo del piano. |
| `thermalAngleDegrees: Double` | 0° | Rotazione dei quattro raggi rispetto agli assi della piazzola già posata, anche sul lato inferiore. |
| `minimumSpokes: Int` | 2 | Da 0 a 4: minimo di raggi completi richiesto; 0 disattiva questa sola verifica. |
| `minimumWidth: Double` | 0 mm | 0 disattiva il filtro dei colli (geometria legacy); positivo attiva filtro e controllo sul piano. |

La distanza `thermalGap` vale anche in modalità `.none`, comprese le piazzole appena fuori
dal contorno del piano. I via mantengono il collegamento pieno. I fori rimangono sempre senza rame. Le nuove
proprietà si applicano con `addZone`/`updateZone`: un'azione, un undo persistente.
Nessuna modifica dei contorni in UI, nessuna ricostruzione separata dei ponticelli.

Il documento scrive **formato 7**, legge **1–7**. In tutti gli stati dello storico i campi
assenti assumono i valori legacy sopra: aprire un file vecchio non cambia il suo rame.
Aggiornare le asserzioni di formato del ponte app; i vecchi lettori rifiutano v7.

## Geometria e diagnostica

Le termiche sottraggono lo spazio attorno alla piazzola lasciando quattro fasce orientate.
Fori, bordo, altre reti e aree vietate sono sottratti insieme: nessun ponticello può
riaggiungere rame dentro un ostacolo. Se un ostacolo taglia solo una parte della larghezza
di un raggio, quel raggio non è contato come completo.

`PCBZoneFill` mantiene `cells` per disegno, pick, snap e connettività. Aggiunge:

- `thermals: [PCBZoneThermal]`: `componentID`, `padID`, `position`, `connectedSpokes`.
  Il conteggio viene dal rame finale conservato, dopo il filtro e la rimozione delle isole.
- `removedNarrowArea: Double`: area rimossa dal filtro di larghezza, in mm²; non comprende
  la successiva eliminazione delle isole prive di collegamento a una piazzola.

Nuovi errori del DRC, con `subjectIDs` e posizione selezionabile:

- `pcb_thermal_starved`: meno raggi completi del minimo richiesto; piano + componente + pad.
- `pcb_thermal_width`: ponticelli sotto il massimo fra minimo piste della rete e minimo del piano.
- `pcb_zone_neck`: il piano filtrato conserva un collegamento che non ammette un percorso
  con la larghezza richiesta. Il punto localizza uno dei lobi interessati, non una quota del collo.

Il filtro di larghezza esegue erosione e dilatazione con un disco poligonale circoscritto,
seguito dal ritaglio sul dominio originale. Le giunzioni artificiali fra celle non sono
ostacoli. Rimuove passaggi lunghi e stretti; se un collo corto sopravvive alla dilatazione,
il controllo di connessione dei lobi erosi lo segnala, evitando di dichiararlo conforme.
L'approssimazione radiale del disco è fino a 0,005 mm: vicino alla soglia può essere conservativa.
Questa regola riguarda il rame del singolo piano; non certifica lo spessore del rame né
la portata elettrica e non misura una larghezza globale unendo piani, piste e pad.

La preview restituisce il candidato completo, compresi errori e riempimenti. Un nuovo piano
con errori che lo riguardano non si conferma; cambiare una regola/area può diagnosticare
il rame esistente senza impedire la riparazione. Conservare la bozza su rifiuto.

## Aggancio T97

Esporre i parametri prima di iniziare il contorno e nel pannello del piano selezionato.
Nascondere/disabilitare i parametri senza effetto nella modalità corrente; non cancellarne
i valori quando si cambia modalità. Distinguere chiaramente «0: disattivato» dal minimo
positivo del piano. Worker cancellabile, UUID, epoca/revisione e protezione delle bozze
restano quelli già collaudati. Le dimensioni devono usare i controlli numerici dell'app.

## Studio e limiti

Riferimento di comportamento: [manuale ufficiale KiCad 9, zone e vincoli delle termiche](https://docs.kicad.org/9.0/it/pcbnew/pcbnew.html).
Studiate separazione fra distanza, larghezza, numero di raggi e minimo del riempimento;
nessun codice KiCad incorporato. Esclusi override per singola piazzola, raggi personalizzati,
priorità fra reti sovrapposte e qualificazione produttiva. Limiti di complessità e
cancellazione producono un rifiuto atomico, mai rame parziale.

## Prove del core

136 test Swift e sei lettori indipendenti PASS; 12 test nuovi termiche/larghezza.
Release su questo Mac: quattro piazzole con filtro0,2 mm, snapshot117,77 ms/queryp95 0,0317 ms;
16 piazzole/64 ponticelli/525 celle, snapshot308,75 ms. In Debug16 piazzole richiedono4,19 s:
il worker cancellabile e la preview asincrona sono necessari. [Evidenze](VALIDATION.md).
Il filtro è conservativo vicino alla soglia: minimo del piano uguale al ponticello può
renderlo insufficiente; il DRC rifiuta l'operazione e richiede ponticelli più larghi.
