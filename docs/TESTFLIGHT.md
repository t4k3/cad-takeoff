# TestFlight — dare CAD Takeoff ai colleghi

Pronto nel progetto (26/09): icona dell'app, manifesto privacy (`PrivacyInfo.xcprivacy`: nessun tracciamento, UserDefaults e date dei file per mostrarle), crittografia dichiarata esente (`ITSAppUsesNonExemptEncryption = NO`: solo HTTPS verso Anthropic/OpenAI e il server MCP locale), sandbox con i soli permessi usati, build Release verificata, script di archiviazione.

I passi qui sotto richiedono il tuo account Apple Developer (team 9F8D583GBV): li fai tu, una volta.

## 1. Una volta sola

1. **Xcode › Settings › Accounts**: il tuo Apple ID con il team 9F8D583GBV. Da lì Xcode crea da solo il certificato *Apple Distribution* e i profili.
2. **App Store Connect › App › +** → *Nuova app*, piattaforma **macOS**, nome «CAD Takeoff» (o quello che preferisci), lingua Italiano, bundle ID **com.takeoff.fusiontakeoff** (se non compare, crealo in *Certificates, Identifiers & Profiles › Identifiers* con la capacità **App Groups** e il gruppo `9F8D583GBV.com.takeoff.fusiontakeoff`), SKU a piacere.

## 2. Ogni versione

```bash
scripts/archive-testflight.sh --upload
```

Archivia in Release, firma per l'App Store e carica. Il numero di build è la data e l'ora, quindi è sempre nuovo. Senza `--upload` crea solo `build/testflight/*.pkg`, da caricare con l'app **Transporter**.

Dopo 10–30 minuti la build compare in App Store Connect › TestFlight (la prima volta chiede la conformità all'esportazione: è già dichiarata nel pacchetto).

## 3. Tester

- **Interni** (fino a 100, con ruolo nel tuo team App Store Connect): subito, senza revisione.
- **Esterni** (colleghi con un semplice indirizzo email, fino a 10.000): crea un gruppo, aggiungi gli indirizzi o un link pubblico. La prima build passa una breve *Beta App Review* di Apple.

Nota per la revisione: «App di progettazione CAD ed elettronica (Circuiti). L'assistente in chat usa Apple Intelligence sul Mac, senza chiave; in alternativa la chiave API personale che l'utente inserisce in Impostazioni (Anthropic o OpenAI). Tutte le funzioni CAD restano disponibili senza assistente. Richiede macOS 27.»

## 4. Cosa fa ogni collega

1. Installa **TestFlight** dal Mac App Store e accetta l'invito.
2. Al primo avvio sceglie la **cartella dei progetti** (Home › Cambia cartella…).
3. Per l'assistente: **Impostazioni › Assistente**, incolla la **propria** chiave Anthropic o OpenAI (resta nel suo Portachiavi, non passa da te).
4. Facoltativo: Claude Desktop (MCP › Collega a Claude Desktop…) e l'add-in per Fusion 360 (Home › Installa add-in…).

## Da sapere

- Il bridge MCP `ftk-mcp` è dentro l'app e ha la sua sandbox: funziona anche nella versione TestFlight.
- I file `.ftk` sono JSON: si scambiano tra colleghi via cartelle condivise; i componenti di un assieme sono percorsi relativi alla cartella dei progetti, quindi conviene la stessa struttura di cartelle.

## Senza TestFlight: .dmg firmato e notarizzato

```bash
scripts/make-dmg.sh
```

Archivia in Release, firma con Developer ID (firma gestita da Apple tramite l'account di Xcode: nessun certificato locale), invia alla notarizzazione, attende l'esito, attacca il biglietto all'app e crea `build/dmg/CAD-Takeoff-<versione>-<build>.dmg` con l'app e il collegamento ad Applicazioni. Chi lo riceve apre il .dmg e trascina l'app in Applicazioni: nessun avviso di Gatekeeper. Non si aggiorna da solo: per una nuova versione si manda un nuovo .dmg.
