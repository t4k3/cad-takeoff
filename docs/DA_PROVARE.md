# Da provare (Ross) — novità dal 26/09

Build: riapri l'app (o TestFlight quando esce). Ogni punto ha i test automatici sul motore; queste
sono le prove a mano, sull'interfaccia.

## Schizzo
- [ ] **Arco** (A): inizio, fine, punto sull'arco. **Spline** (B): punti, Invio o clic sul primo punto.
- [ ] **Raccordo** e **Smusso** su un angolo (raggio/distanza nelle OPZIONI); cambia la quota R: i lati restano fermi.
- [ ] **Taglia** (T): il pezzo sotto il cursore diventa rosso, clic lo toglie. **Estendi**: clic vicino a un estremo.
- [ ] **Offset** (O): clic sulla forma, poi sul lato. Prova su un rettangolo raccordato.
- [ ] **Specchio**: clic sulla linea d'asse, poi sulle forme; sposta l'originale, la copia segue.
- [ ] Vincolo **Simmetrico** (VINCOLI): due punti e la linea.
- [ ] **Parametri** (ƒ): crea `larghezza = 40`, scrivi `larghezza / 2` in una quota → «fx:»; cambia il parametro.
- [ ] Arco disegnato dalla fine di una linea nella sua direzione: tangenza automatica.
- [ ] Piano di schizzo **inclinato** (campo «Inclina» nella scelta del piano).
- [ ] Piani di costruzione: **3 punti** (vertici/centri/punti medi), **Medio** fra due facce parallele, clic su un cilindro → piano **tangente**.

## Solidi
- [ ] **Rivoluzione** (Schizzo › CREA): aree + linea d'asse (meglio di costruzione), angolo, verso.
- [ ] **Estrudi**: Estensione Simmetrica / **Passante**; **Sformo** in gradi; anche nella distanza un'espressione.
- [ ] **Guscio** (SOLIDO › MODIFICA): clic sulla faccia sopra di una scatola, spessore.
- [ ] **Sposta**: corpo selezionato, X/Y/Z e rotazione.
- [ ] **Serie/Specchio** con un foro o un taglio selezionato: ripete l'operazione.
- [ ] **Raccordo su tutti gli spigoli** dell'auto: solidi chiusi; angoli sferici sui box.

## Assiemi
- [ ] **Giunto**: bordo del foro sul pezzo che si muove, poi dove va; Rotazione, angolo.
- [ ] **Interferenze** e **Esplosa** (ASSIEME).
- [ ] **Misura**: due facce/spigoli → distanza minima; un bordo tondo → Ø.

## Verso il fornitore
- [ ] **STEP** (STAMPA › STEP): aprilo in Fusion — fori, perni, raccordi devono essere superfici vere.
- [ ] **Tavola** (STAMPA › Tavola, ⇧⌘P): PDF o DXF; casella «in sezione» per i torniti; tabella fori.
- [ ] **Tavola di piega** (LAMIERA › SVILUPPO › Tavola): sviluppo quotato, pieghe P1… su/giù, tabelle pieghe e fori.
- [ ] **Risvolto / orlo** (Lamiera › «Sulla punta»): profilo a C, a Z, orlo 180°; scatola con risvolti → scarichi negli angoli dello sviluppo.
- [ ] **Tavola con le quote degli schizzi**: quota due fori in uno schizzo (distanza orizzontale), estrudi, STAMPA › Tavola: la quota compare nella vista dall'alto.
- [ ] **Tornito**: profilo su XZ con quote dall'asse, Rivoluzione, Tavola (anche «in sezione»): le quote dall'asse escono come Ø.
- [ ] **Tagli nello sviluppo**: schizzo su una faccia della lamiera, rettangolo/asola, Estrudi in taglio Passante: la finestra compare nello sviluppo, nel DXF e nella tavola di piega.
- [ ] **Sezione** (barra in basso, forbici): piano in squadro a X/Y/Z, cursore per spostarlo, «Tieni l'altra metà»; l'interno tagliato è arancio.
- [ ] **Giunto trascinabile**: nel comando Giunto (e modificandolo) una freccia sull'asse: trascinala per girare (Rotazione) o far scorrere (Scorrimento).
- [ ] **Schizzo più facile**: la linea si aggancia ai lati e ai cerchi (◇), agli incroci (×), si allinea in orizzontale/verticale coi punti già disegnati (guida tratteggiata); si finisce con doppio clic, Esc o cambiando strumento.
- [ ] **Vincoli sotto un pulsante** (Schizzo › VINCOLI › Vincoli): la lista si apre sotto, un clic per scegliere.
- [ ] **Schizzo su una faccia qualsiasi**: SOLIDO › Schizzo, passa sulle facce (si illuminano), clic su una piana anche di smussi/STL; selezione ora arancio pieno con contorno spesso.
- [ ] **Pezzi importati da Fusion**: facce piane intere (schizzo su faccia, punto medio dei bordi), fori e perni riconosciuti come cilindri (misura Ø, centro, giunto, piano tangente). Reimporta il pezzo o riapri il file.

## Import modificabile da Fusion (nuovo)
- [ ] Reinstalla il plug-in dall'app (Home › «Installa add-in…»): copia anche `fusion_history.py`. In Fusion riavvia l'aggiunta.
- [ ] Un pezzo semplice (schizzo quotato + estrusione + raccordo): «Esporta per CAD Takeoff», aprilo qui. Nella barra di stato: «Da Fusion: N corpi modificabili…». Doppio clic sullo schizzo: quote e vincoli ci sono; cambia un parametro in «Parametri».
- [ ] Rilancia lo script «Importa progetto in CAD Takeoff» su «025 RobotVolley»: riesporta tutto (i vecchi .ftk senza cronologia non vengono saltati). Mandami import-fusion.txt e i messaggi «non convertiti» dei pezzi che ti servono.

## Curve lisce a schermo
- [ ] Un cilindro o un foro grande: avvicinati molto (zoom): dopo un attimo le faccette spariscono (la vista si rifà più fine in background). Allontanandoti torna quella normale; selezionare facce e spigoli funziona uguale.

## Export più liscio per la stampa
- [ ] Esporta STL o 3MF: nel pannello «Qualità fine: curve lisce» (predefinita, ricordata) — un cilindro o un raccordo grande nello slicer non mostra più le faccette; «Qualità normale» = come prima. Il modello a schermo non cambia.

## Tavola a schermo
- [ ] ⇧⌘P (o CREA/ESPORTA › Tavola): si apre la tavola come verrà stampata. Quota (D): clic su un estremo o metà di uno spigolo (i punti agganciabili si accendono), clic su un secondo punto della stessa vista, poi clic sopra/sotto (quota orizzontale), a lato (verticale) o in mezzo / con ⌥ (allineata). Seleziona: clic su una quota, trascinala per allontanarla o avvicinarla, Canc la toglie (una automatica torna con «Ripristina quote automatiche»). ⌘Z annulla. Esporta… → PDF o DXF con le stesse quote; chiudi e riapri il disegno: le quote restano.

## Giunti trascinabili
- [ ] Assieme con un giunto di Rotazione: clic sul pezzo che si muove (selezionato), poi trascinalo: gira attorno all'asse seguendo il mouse (gradi interi, valore nella barra in basso); al rilascio un passo solo di ⌘Z. Scorrimento: scorre lungo l'asse. Cilindrico: gira, con ⌥ premuto scorre. Trascinare altrove (o un pezzo non selezionato) gira la vista come sempre.

## Lamiera a base libera
- [ ] Schizzo sul piano XY → un profilo chiuso (esagono, forma a L…) → CREA › **Lamiera**: esce la base piana; clicca i bordi da piegare (di nuovo per toglierli), altezza/angolo/risvolto come sempre → OK. LAMIERA › Sviluppo: la sagoma stesa con le pieghe. Due lati piegati che si incontrano in un angolo rientrante: messaggio che si sovrappongono. Un solo lato piegato che finisce in un angolo rientrante (la L): la flangia si ferma uno spessore prima e nello sviluppo c'è la fessura con il fondo tondo che la stacca dalla base.

## Circuiti (1.0.0)
- [ ] Scheda **CIRCUITI** › Esempio: scheda verde, piazzole oro (sopra) e blu (sotto), sigle, linee bianche dei collegamenti da sbrogliare; passa sulle piazzole: la rete si accende in arancio.
- [ ] Trascina un componente (anteprima dal vivo, collegamenti che seguono), R ruota, F cambia lato; ⌘Z annulla una mossa alla volta.
- [ ] VERIFICHE a destra: clic su un problema → seleziona il componente. PRODUZIONE › JLCPCB: se manca qualcosa il messaggio dice cosa (l'esempio ha componenti fittizi: non ordinare).
- [ ] Nuovo / Salva / Apri (.ftkc); chiudendo con modifiche chiede se salvare.
- [ ] **Costruire un circuito** (CIRCUITI › CREA): Componente → scegli, sigla/valore → clic sulla scheda (resta attivo per R2, R3…; Esc finisce). Collega → clic su una piazzola, poi su un'altra: compare la linea del collegamento. Scheda → misure con anteprima tratteggiata. Elimina (o Canc). Ogni passo si annulla con ⌘Z. Nota: da «Nuovo» la libreria è vuota finché Codex non consegna i modelli generici; intanto prova sull'Esempio.
- [ ] **Librerie** (CIRCUITI › LIBRERIA): Importa un .kicad_mod / .kicad_sym (scegli il simbolo) / EasyEDA .json → anteprima e avvisi → Importa. Poi «Nuovo tipo»: simbolo + impronta, controlla pin → piazzole, Crea → lo trovi in CREA › Componente.
- [ ] **Assistente sul Mac** (pannello Assistente › fornitore «Apple Intelligence — sul Mac, senza rete»): «Crea un cubo di 20 mm di lato» → cubo creato, annullabile. Niente chiave API. Se Claude/ChatGPT non hanno la chiave parte già su questo.
- [ ] **Schema** (CIRCUITI › Schema): Componente → clic sul foglio (il primo foglio nasce da solo); Filo: clic su un pin (□), clic nel vuoto per le pieghe, clic sull'altro pin; Etichetta su un pin → nome (VCC…); NC; Giunzione su un filo. Seleziona e trascina un simbolo, R ruota, M specchia, Canc elimina. Poi PCB: «N da posare dallo schema» → clic sulla scheda: compaiono i collegamenti. Fogli dal menu in alto.
- [ ] **Piste** (CIRCUITI › PCB › SBROGLIO): Pista (X) → clic su una piazzola collegata → clic per le pieghe (45°, / cambia la piega) → clic sulla piazzola della stessa rete: la linea bianca sparisce. Il tratto verso il mouse è rosso con «Non confermabile» se tocca un'altra rete o esce dalla scheda. V (o il menu Strato) mette una via e continua sull'altro lato; ⌫ toglie l'ultimo punto, Invio finisce, Esc annulla. Clic su una pista: nel pannello rete, strato, lunghezza e larghezza (cambiabile); Canc la elimina; ⌘Z. Scheda: strati (2…32, solo senza rame) e regole. Gli errori del rame compaiono in VERIFICHE e sulla scheda (×); un clic sull'errore lo cerchia.
- [ ] **Classi e aree vietate** (CIRCUITI › PCB › SBROGLIO): Classi → «Potenza» (+) → pista 0,5 mm, via 0,8/0,4 → Applica; nella colonna RETI metti una rete in Potenza: una Pista su quella rete parte da 0,5 mm e le via sono 0,8/0,4 (barra in basso). Cambia un minimo sopra il rame già tracciato: prima di Applica dice quanti errori crea. Chiudi con modifiche non applicate: chiede Applica/Scarta/Annulla. Area vietata (K) → due clic e Invio = rettangolo (o più clic e clic sul primo punto); se copre una pista, prima di confermare dice «conflitti col rame». Passa sopra un'area: si illumina in arancio; clic la seleziona (nome, strati, cosa vieta), trascinala, Canc la elimina. Una pista dentro un'area è rifiutata.
- [ ] **Piani di rame** (CIRCUITI › PCB › SBROGLIO › Piano, tasto P): scegli la rete in basso (o parti cliccando su una piazzola: ne prende la rete) → clic sugli angoli; due clic e doppio clic (o Invio, o Chiudi) = rettangolo. Prima di confermare vedi già il riempimento del motore, lontano dalle altre reti, dai fori, dal bordo e dalle aree vietate. Clic dentro il piano lo seleziona (nome, rete, strato, «Togli le isole», area del rame); trascinalo, Canc lo elimina, ⌘Z. Due piani di reti diverse sovrapposti sullo stesso strato: rifiutato, la bozza resta. Esc mentre il motore lavora annulla senza aggiungere nulla. Collegamento pieno: termiche e colli minimi non ci sono ancora.

## UI Liquid Glass e lingue (T112)
- [ ] Finestra: il 3D arriva ai bordi (niente fasce grigie); Browser, Parametri/Assistente, la barra strumenti in alto, la timeline e la barra di stato sono **isole di vetro** staccate dal bordo, con angoli arrotondati e un filo chiaro sul bordo. Nessun testo o chip del viewport finisce sotto le isole (ruota e zooma per controllare).
- [ ] Barra del titolo in stile Xcode (una riga sola): a sinistra le schede dei disegni con «+», al centro il selettore SOLIDO/LAMIERA/ASSIEME/STAMPA/CIRCUITI, a destra Annulla/Ripeti, Assistente (⌘L), Browser e Parametri; il vecchio ribbon alto non c'è più e la barra strumenti cambia contenuto con la modalità.
- [ ] Ridimensiona la finestra stretta e larga, poi ingrandisci il testo in Impostazioni di Sistema › Accessibilità › Dimensioni testo: le isole restano dentro la finestra e il 3D non viene coperto dai pannelli.
- [ ] Aspetto chiaro e scuro (Impostazioni di Sistema › Aspetto): materiale, ombre e filo di bordo si adattano; nessun testo illeggibile.
- [ ] **Lingue**: Impostazioni di Sistema › Generali › Lingua e regione › App → CAD Takeoff → English, riapri: barre, schede, Browser, Parametri, timeline, toolbar e suggerimenti (passa il mouse sui pulsanti) in inglese; poi 简体中文: idem in cinese; torna a Italiano: tutto come prima. Controlla anche CIRCUITI (Schema/PCB, Gerber/Assemblata/3D), SCHIZZO (strumenti del dock, menu Vincoli, quota), Home (viste vuote e cartelle) e la conferma di eliminazione di uno schizzo collegato a un'estrusione.
- [ ] Limite noto: le descrizioni degli strumenti AI (`Model/Tools/CADToolCatalog`, `CircuitModel+Tools`) e i testi dei problemi del motore elettronico (`ElectronicsCore`, dominio Codex) restano in italiano: non sono UI ma parlano ai modelli. Tutti gli altri messaggi, comprese le indicazioni sulla chiave API dell'assistente, sono tradotti (seguito T112/T114).

## Seguito T112 — i18n pulita e Home stile Pixelmator
- [ ] **Titolo finestra** (cinese): apri un disegno e modificalo → «未命名 — 已修改» (niente «Senza titolo»); idem per un circuito.
- [ ] **Salvataggio** (cinese): chiudi con modifiche → il dialogo (titolo, testo, Salva/Non salvare/Annulla) è in cinese.
- [ ] **Pannello comando** (cinese, inglese): GUSCIO → «抽壳» (non più «GUSCIO»); Foro, Raccordo, Lamiera, Serie, Filettatura: etichette, note e opzioni tradotte; i valori numerici restano «2 mm».
- [ ] **Lamiera** (cinese): la riga della regola («V 模口…»), lo sviluppo («展开 … 质量 ≈ … kg») e le opzioni risvolto/orlo sono tradotte.
- [ ] **Barra di stato** (cinese): «1 个实体» / «N 个实体», «1 个错误», i conteggi dei circuiti; nessuna parola italiana.
- [ ] **Home** (cinese, inglese): colonna sinistra con icona, nome, versione, «新建设计» / «新建电路» / «打开…» / «选择文件夹…», menu «更多», selettore progetti; destra con breadcrumb, ricerca, «新建文件夹»; stato vuoto tradotto.
- [ ] **Stato vuoto Home**: cerca qualcosa che non esiste → «未找到设计»; nessun progetto → «没有项目».
- [ ] **Lingue**: Impostazioni di Sistema › Generali › Lingua e regione › App → English / 简体中文 / Italiano, riapri ogni volta; in cinese e inglese non resta italiano nei punti qui sopra.
- [ ] **Assistente** (cinese, senza chiave configurata): pannello «AI 助手» → il riquadro con la chiave legge «或者，在此应用内使用助手：要使用 Claude，请在「设置 → 助手」中输入你的 Anthropic API 密钥。»; con OpenAI e con Apple Intelligence non disponibile, gli avvisi sono tradotti.


## Seguito T115 — barra stile Xcode e finestra di benvenuto
- [ ] All'avvio (prima volta dopo aver tolto/rimesso la spunta) compare la **finestra di benvenuto separata**: 1032×672, nessun titolo né semafori, trascinabile dal fondo. A sinistra icona grande, «CAD Takeoff», versione/build, le pillole Nuovo disegno / Nuovo circuito / Apri… / Scegli cartella…, il menu «Altro» e in basso «Mostra questa finestra all'avvio»; a destra il menu del progetto, la ricerca, «Nuova cartella» e la griglia dei recenti.
- [ ] Togli «Mostra questa finestra all'avvio», chiudi la finestra di benvenuto e riapri l'app: non compare; ⌘⇧H la riapre (e la X in alto a sinistra la chiude).
- [ ] Apri un disegno o un circuito dalla finestra di benvenuto: la finestra si chiude e il documento compare nella finestra principale; Esc o la X tornano al documento già aperto.
- [ ] Finestra principale: schede nella barra del titolo (a sinistra), modalità al centro, Annulla/Ripeti/Assistente/Browser/Parametri a destra; il dock strumenti è la prima riga sotto la barra. Ridimensiona stretta/larga: nulla si sovrappone al 3D.
- [ ] Lingue: English → benvenuto con «Welcome», «Show this window at launch», tooltip «Back to …(Esc)»; 简体中文 → 「欢迎」「启动时显示此窗口」「返回 …(Esc)」.

## Seguito T116 — Home stile Strophe, nomi file e hint
- [ ] **Estensione in cinese**: con l'app in 简体中文, Home › Nuovo disegno (o ⌘N e poi Salva) → nel Finder il file si chiama `新建设计.ftk`, non `新建设计。ftk`; idem circuito: `新建电路.ftkc`. Riapri il file: si apre normalmente.
- [ ] **Hint del viewport**: la riga «移动：环绕 · ⌥ 拖动 / 双指：平移 · 滚轮 / 捏合：缩放» ora sta **al centro in basso, sopra la capsula di navigazione**, staccata dall'oggetto tree a sinistra; sparisce quando c'è un comando aperto o sei in SCHIZZO.
- [ ] **Home (Strophe)**: colonna sinistra con icona arrotondata 104, «CAD Takeoff» grande, versione/build, quattro schede con icona arancione, titolo + sottotitolo e freccia (Nuovo disegno, Nuovo circuito, Apri…, Scegli cartella…), in basso «Altro» e la spunta; hover che schiarisce la scheda.
- [ ] **Home — recenti**: colonna destra con menu progetto, breadcrumb, ricerca e righe (icona, nome, percorso/data relativa, «⋯» con Apri/Rinomina/Duplica/Mostra nel Finder/Cestino); doppio clic apre, la riga aperta ha il pallino arancione e il bordo acceso; stato vuoto con icona, titolo e suggerimento allineati in alto.
- [ ] Lingue: in English/简体中文 titoli delle schede, sottotitoli, stato vuoto e menu sono tradotti; il nome del file resta con il punto ASCII.

## Seguito T117 — firma che non si resetta
- [ ] Dopo `xcodegen generate` (o `scripts/build.sh`, o una build da Xcode), Signing & Capabilities mostra ancora **il tuo team** (Chuansuo Kang – Personal Team), non quello dell'autore originale.
- [ ] Build firmata da Xcode: `codesign -dv CAD Takeoff.app` riporta `TeamIdentifier=3XV7UWT8UV`.
- [ ] Cambiare team: modifica **Config/Local.xcconfig** (`DEVELOPMENT_TEAM = ...`, file non versionato), non l'interfaccia di Xcode — la UI scrive nel progetto generato, che viene riscritto a ogni rigenerazione. `Config/Signing.xcconfig` è versionato e include il file locale se c'è.

## Seguito T118 — avvio pulito e Home a tutto schermo
- [ ] Con «Mostra questa finestra all'avvio» spuntata, all'avvio compare **solo** la finestra di benvenuto: nessuna finestra workspace vuota dietro (e nessun lampo).
- [ ] Togli la spunta, chiudi e riapri l'app: all'avvio compare **solo** il workspace; il pulsante Home (⌘⇧H) apre il benvenuto al primo clic.
- [ ] Dal benvenuto: Nuovo disegno / Nuovo circuito / Apri… / doppio clic su una riga → il workspace si apre con il documento e il benvenuto si chiude.
- [ ] La finestra di benvenuto non ha più la striscia vuota in alto: il contenuto (icona, titoli, schede, lista) usa tutti i 672pt; la X è nell'angolo in alto a sinistra e il fondo resta trascinabile.

## Seguito T119 — MCP in alto a destra, barra inferiore unica e pannelli laterali lunghi
- [ ] **MCP**: il pallino di stato «MCP» (con il numero di client) è in alto a destra nella barra del titolo; cliccandolo si apre il pannello dei connettori. Non è più nella capsula in basso.
- [ ] **Barra inferiore**: una sola capsula **a tutta larghezza** con, da sinistra: gli otto pulsanti del viewport (Corpi/Facce/Spigoli, Home, Adatta, Proiezione, Stile, Sezione), la timeline, le statistiche e il messaggio di stato con la versione a destra. La vecchia barra di navigazione flottante sopra il 3D non c'è più; il suggerimento «Trascina: orbita…» resta sopra la barra.
- [ ] **Statistiche**: corpi, triangoli, volume e «mm · Z↑» sono al centro della barra inferiore, subito a destra della timeline; il pannello destro non le mostra più.
- [ ] **MCP più largo**: in alto a destra il pulsante «MCP» ha un'area di clic più ampia (minimo 64 pt).
- [ ] **Avvio**: con «Mostra questa finestra all'avvio» attivo all'apertura compare **solo** il Benvenuto; il workspace non viene più ripristinato dietro (restoration disattivata sulla scena del workspace). Con l'opzione spenta si apre solo il workspace.
- [ ] **Pannelli laterali**: Browser e Parametri scendono fino a poco sopra la barra inferiore. Il margine in alto (sotto la barra del titolo) e quello in basso (sopra la barra inferiore) sono uguali (8 pt).
- [ ] **Timeline**: è dentro la barra inferiore, tra i pulsanti e le statistiche; quando ci sono molti passi scorre in orizzontale senza spingere fuori gli altri elementi.
- [ ] **CIRCUITI**: la barra inferiore mostra solo messaggio e conteggi del circuito (niente pulsanti 3D); i pannelli laterali hanno la stessa altezza.
- [ ] **ChatGPT in English/简体中文**: Connettori MCP › ChatGPT → descrizione, i tre passi, «Copia configurazione»/«Copia avvio»/«Copia diagnosi», «Copiato» e «Inserisci il tunnel_id per generare il comando.» sono tradotti; nessuna frase italiana.

## Seguito T120 — macOS 14 minimo
- [ ] **Avvio**: `Info.plist` dell'app compilata riporta `LSMinimumSystemVersion = 14.0`; su macOS 14/15 l'app si apre e funziona (su macOS 26+ invariata).
- [ ] **Vetro**: su macOS 14 pannelli, capsule, pannello comandi e chip del viewport usano `regularMaterial` (niente Liquid Glass, che è macOS 26); su macOS 26/27 restano in vetro.
- [ ] **Avvio con una finestra sola** (senza le API di scena di macOS 15): con «Mostra questa finestra all'avvio» compare solo il Benvenuto (il workspace vuoto viene nascosto); senza la spunta compare solo il workspace; nessuna finestra ripristinata dalla sessione precedente.
- [ ] **CIRCUITI › 3D**: su macOS 14 la vista 3D della scheda assemblata mostra «Vista 3D non disponibile — Richiede macOS 15 o successivo.» invece di fallire; su macOS 15+ funziona come prima.
- [ ] **Assistente**: Apple Intelligence compare solo da macOS 27; su macOS 14 restano Claude e ChatGPT.
- [ ] **Build pulita**: `scripts/build.sh` senza warning (niente default Codable nei `let`, niente `Text + Text`).
