# ChatGPT → Fusion Takeoff

Responsabile: Codex. Stato: preparazione locale implementata; collegamento remoto
non attivato né verificato. Il catalogo di 12 strumenti è quello comune del Model.

## Due modalità distinte

- **Chat nell'app:** provider OpenAI nelle Impostazioni → Assistente, con una chiave
  API personale nel Portachiavi. Il ciclo esegue gli strumenti locali del Model.
- **ChatGPT esterno:** connettore MCP attraverso Secure MCP Tunnel. Non utilizza
  la chiave della chat dell'app e non richiede di esporre il Mac pubblicamente.

Il percorso scelto per il prototipo è `ChatGPT → tunnel-client → ftk-mcp → MCP
locale → DesignModel`. Il bridge di Claude viene riusato come trasporto condiviso;
scopre il token locale senza copiarlo nelle istruzioni o negli argomenti di avvio.

## Preparazione

Dalla cartella del progetto:

```sh
scripts/install-claude-connector.sh
python3 scripts/connect-chatgpt.py check
```

Lo script di installazione compila il bridge comune; senza opzioni non modifica
la configurazione di Claude Desktop. Per il tunnel installare il client ufficiale
seguendo [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels).
Creare il tunnel nelle impostazioni Platform, associarlo al workspace ChatGPT
corretto e annotare il suo `tunnel_id`. Servono i permessi di creazione/uso tunnel;
la disponibilità della modalità sviluppatore è separata.

Configurare la chiave runtime `CONTROL_PLANE_API_KEY` nel terminale locale con
input nascosto, senza scriverla nel repository o nella chat. Per zsh:

```sh
read -rs 'CONTROL_PLANE_API_KEY?Chiave runtime tunnel: '
export CONTROL_PLANE_API_KEY
```

Configurare il profilo (sostituire il segnaposto con l'ID reale):

```sh
python3 scripts/connect-chatgpt.py configure --tunnel-id tunnel_INSERIRE_ID_REALE
python3 scripts/connect-chatgpt.py doctor
python3 scripts/connect-chatgpt.py run
```

`--dry-run` mostra solo il comando. Il profilo è `fusion-takeoff`. `--bridge`
permette un percorso diverso. Il client resta in esecuzione durante la connessione;
interromperlo con Ctrl-C disconnette ChatGPT dal CAD. Avviare l'app compilata e
abilitare MCP dal suo pannello Connettori.

## Connessione in ChatGPT

Nella modalità sviluppatore creare una connessione MCP, scegliere **Tunnel** e
selezionare il tunnel associato al workspace. Verificare i 12 strumenti e aprire
una conversazione con il connettore abilitato. La procedura aggiornata è nella
[guida ufficiale](https://developers.openai.com/plugins/deploy/connect-chatgpt).
Il helper non modifica l'account ChatGPT e non crea tunnel automaticamente.

Prova: «Usa Fusion Takeoff: leggi la scena, crea una base 40 × 30 × 5 mm,
verifica il volume, porta l'altezza a 8 mm e annulla questa ultima modifica».
Il risultato atteso è una base alta 5 mm, volume 6000 mm³, con lo stesso ID.
Per evitare ambiguità usare una scena vuota o verificare la feature creata per ID.

## Diagnostica e prove

- `check` verifica solo presenza locale degli eseguibili e della variabile della
  chiave, senza stamparne il valore. Non prova permessi o connessione remota.
- `doctor` appartiene al client ufficiale; esamina configurazione e raggiungibilità.
- Il Model rifiuta revisioni obsolete e parametri geometrici invalidi. Su conflitto
  il modello deve rileggere lo stato prima di riprovare.
- Se il tunnel non compare, verificare associazione workspace e permessi di uso.
- La v1 non include booleane, lamiera, assiemi o storico parametrico persistente:
  sono nel grafo di sviluppo, non vanno simulati con risposte testuali.

Verificati localmente: tre test del launcher (quotatura percorsi, ID, comandi),
12 tool del Model, test CAD e build Xcode. Da verificare con credenziali reali:
installazione del client ufficiale, autenticazione tunnel, discovery in ChatGPT,
richiesta naturale end-to-end. Queste verifiche restano nel task T55.

## Colleghi con TestFlight, senza repository

Il bridge è previsto nel bundle dell'app (`Contents/MacOS/ftk-mcp`, integrazione
T56 di Claude). Copiare il percorso dal pannello Connettori. Dopo aver installato
il client ufficiale e configurato la propria chiave runtime/tunnel, si possono
usare direttamente questi comandi, senza Python o Xcode:

```sh
tunnel-client init --sample sample_mcp_stdio_local --profile fusion-takeoff \
  --tunnel-id tunnel_INSERIRE_ID_REALE \
  --mcp-command "'/Applications/FusionTakeoff.app/Contents/MacOS/ftk-mcp'"
tunnel-client doctor --profile fusion-takeoff --explain
tunnel-client run --profile fusion-takeoff
```

Se l'app è altrove usare il percorso copiato, conservando le virgolette.
Ogni collega configura il proprio account e la propria chiave: nessuna credenziale
è inclusa nel bundle. Il helper Python è solo una comodità per lo sviluppo locale.
`ChatGPTConnector.swift` espone alla UX il comando quotato e i comandi diagnostici.
L'inclusione/firma del bridge e la pubblicazione TestFlight sono verifiche separate.
