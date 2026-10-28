# HyperSpace

Keyboard mapper, mouse mapper e tiling window manager per macOS in un'unica app da menu bar.
Swift + AppKit, nessuna dipendenza, binario da ~270 KB.

**Unico permesso richiesto: Accessibilità.** Niente Input Monitoring, niente Screen Recording,
niente notifiche, niente driver/kext, niente root.

## Build

Servono solo i Command Line Tools (Xcode non è necessario).

```bash
make app        # build/HyperSpace.app (release, firmata ad-hoc)
make run        # build + avvio
make install    # copia in /Applications
```

Al primo avvio macOS chiede il permesso di Accessibilità; HyperSpace parte da solo appena viene concesso.

> **Firma e permesso.** macOS lega il permesso di Accessibilità al *designated requirement* della firma.
> Una firma ad-hoc normale lo basa sull'hash del binario, che cambia a ogni rebuild: il permesso si perde
> anche se in Impostazioni l'interruttore resta acceso. Per questo `make app` firma ad-hoc fissando il
> requisito al bundle id (`identifier "com.alessandrorebosio.HyperSpace"`), così il permesso sopravvive ai rebuild.
> È una scelta comoda per lo sviluppo, ma più debole: qualunque app firmata con quel bundle id
> erediterebbe il permesso. Per un legame forte crea un certificato self-signed (*Accesso Portachiavi →
> Assistente Certificato → Crea un certificato*, nome `HyperSpace Dev`, *Radice autofirmata*, *Firma codice*):
> se esiste, `make app` lo usa automaticamente e il permesso resta legato al certificato.

## Configurazione

`~/.config/hyperspace/config.json` — creato al primo avvio, ricaricato automaticamente a ogni salvataggio.
Se il file ha un errore l'icona in menu bar diventa ⚠︎ e il menu mostra il messaggio; resta attiva l'ultima config valida.

```json
{
  "keyboard": {
    "remap": [
      { "from": "caps_lock", "to": "hyper" },
      { "from": "right_option", "to": "escape" }
    ],
    "bindings": [
      { "keys": "hyper+h", "action": "focus left" },
      { "keys": "cmd+alt+t", "action": "launch Terminal" }
    ]
  },
  "mouse": {
    "reverseScroll": true,
    "dragModifier": "ctrl+alt",
    "buttons": [ { "button": 3, "action": "key cmd+[" } ]
  },
  "tiling": {
    "enabled": true, "layout": "tall", "gap": 8, "padding": 8, "masterRatio": 0.55,
    "floating": ["com.apple.finder"]
  }
}
```

### Keyboard
| Chiave | Significato |
|---|---|
| `remap` | Rimappature 1:1 di qualsiasi tasto, per tastiera (vedi sotto). |
| `bindings` | Combinazione → azione. Modificatori: `cmd`, `alt`/`opt`, `ctrl`, `shift`, `hyper`, `meh` (alt+ctrl+shift). |

#### Rimappature (`remap`)

Il modo più comodo è **Settings… → Keyboard** (menu bar, ⌘,): clicchi il campo, premi il tasto
fisico, poi scegli la destinazione con **Press Keys…** premendo quello che vuoi ottenere: un tasto,
una combinazione con tasto (tieni ⌘ e premi Spazio → ⌘ Space) o solo modificatori (tieni ⇧⌃⌥ insieme e
rilascia → ⌃⌥⇧). In alternativa c'è l'elenco di tutti i tasti. Infine scegli su quali tastiere vale. Le modifiche vengono scritte in `config.json` e applicate subito.

```json
"remap": [
  { "from": "caps_lock",    "to": "escape" },
  { "from": "left_command", "to": "left_option",  "keyboard": "external" },
  { "from": "left_option",  "to": "left_command", "keyboard": "external" },
  { "from": "fn",           "to": "left_control", "keyboard": "builtin" },
  { "from": "caps_lock",    "to": "shift+ctrl+alt" },
  { "from": "right_command","to": "cmd+space" },
  { "from": "right_option", "to": "none",         "keyboard": "Magic Keyboard" }
]
```

- **Ogni tastiera**: integrata, USB, Bluetooth, anche collegate dopo l'avvio o dopo lo stop. HyperSpace
  riceve da IOKit l'evento di nuova tastiera e la configura subito; al risveglio dallo stop ricontrolla tutto.
- `keyboard` (facoltativo): `all` (default), `builtin`, `external`, oppure una parte del nome del prodotto
  (es. `"USB Receiver"`, `"Keychron"`). Se più regole rimappano lo stesso tasto su una tastiera vince la più
  specifica: nome prodotto > builtin/external > all.
- Gli scambi (cmd ↔ option) funzionano: tutte le regole di una tastiera vengono applicate insieme.
- `"to": "none"` disattiva il tasto.
- **Caps Lock rimappato non attiva più il maiuscolo.** Su macOS recenti il layer HID continua ad alternare il
  blocco maiuscole anche se il tasto è rimappato; quando una regola parte da `caps_lock`, HyperSpace toglie il
  flag maiuscolo dagli eventi e spegne subito il blocco (serve Accessibilità). Vale per tutte le tastiere.
- **Combinazioni**: `to` può essere più tasti uniti da `+`, cioè modificatori (`ctrl`, `alt`, `shift`, `cmd`, anche
  `left_shift` ecc.) più al massimo un tasto. `hyper` = ⌃⌥⇧⌘, `meh` = ⌃⌥⇧.
  - Solo modificatori (`shift+ctrl+alt`): restano premuti finché tieni premuto il tasto, valgono per i tasti e i clic,
    e funzionano nelle `bindings` (`hyper+h`, `meh+k`…).
  - Con un tasto (`cmd+space`): premere il tasto equivale a premere la combinazione.
  - Il layer HID fa solo 1:1, quindi il tasto viene rimappato su un tasto "portante" inutilizzato (F13–F20,
    saltando quelli che usi) che l'event tap traduce nella combinazione. Massimo 8 combinazioni diverse; richiede
    il permesso di Accessibilità.
- `hyperKey: "caps_lock"` è ancora accettato come scorciatoia per `{ "from": "caps_lock", "to": "hyper" }`.
- Le rimappature vivono nel layer HID del sistema (la proprietà `UserKeyMapping` di ogni tastiera, la stessa
  usata da `hidutil`): avvengono prima che qualunque app veda il tasto, costano zero CPU e **non richiedono
  alcun permesso**, quindi sono attive anche prima di concedere Accessibilità. All'uscita vengono rimosse.
- HyperSpace gestisce l'intera `UserKeyMapping`: eventuali mappature impostate a mano con `hidutil` vengono sostituite.

#### Nomi dei tasti

| Gruppo | Nomi |
|---|---|
| Lettere, numeri | `a`–`z`, `0`–`9` |
| Funzione | `f1`–`f24` (`f21`–`f24` solo come destinazione/sorgente di remap) |
| Modificatori | `left_command` `right_command` `left_option` `right_option` `left_control` `right_control` `left_shift` `right_shift` `caps_lock` `fn` (alias `globe`) |
| Editing | `return` `escape` `tab` `space` `delete` `forward_delete` `insert` `application` |
| Navigazione | `left` `right` `up` `down` `home` `end` `page_up` `page_down` |
| Punteggiatura | `minus` `equal` `left_bracket` `right_bracket` `backslash` `semicolon` `quote` `grave` `comma` `period` `slash` `section` `non_us_pound` (anche come simboli: `-` `=` `[` `]` `;` `'` `` ` `` `,` `.` `/` `\` `§`) |
| Tastiere PC | `print_screen` `scroll_lock` `pause` |
| Tastierino | `keypad_0`–`keypad_9` `keypad_period` `keypad_enter` `keypad_plus` `keypad_minus` `keypad_multiply` `keypad_divide` `keypad_equal` `keypad_comma` `keypad_clear` |
| Internazionali | `international1` `international3` `lang1` (kana) `lang2` (eisu) |
| Multimediali (solo remap) | `mute` `volume_up` `volume_down` `play_pause` `next_track` `previous_track` `eject` `brightness_up` `brightness_down` |
| Qualsiasi altro tasto | codice HID esadecimale: `0x39` (pagina tastiera) oppure `0xC000000E2` (`pagina << 32 \| usage`) |

Note: `fn` è rimappabile sulle tastiere Apple; sulla maggior parte delle tastiere PC il tasto fn è gestito dal
firmware e non arriva al Mac. I tasti multimediali e `f21`–`f24` non generano eventi tasto in macOS, quindi
si possono rimappare ma non usare nelle `bindings`.

### Mouse

Dalla finestra **Settings… → Mouse**: interruttore per invertire lo scroll della rotellina e mappatura dei tasti.
**Add Button**, clicca il tasto del mouse sopra la finestra (tenendo premuti dei modificatori se vuoi che la
mappatura valga solo con quelli), poi premi la combinazione che deve inviare, scegli un'azione pronta
oppure **Disable Button**. Azioni pronte:

- **Navigation**: Back / Forward universali, indipendenti da lingua e layout di tastiera. HyperSpace preme la
  voce di menu dell'app in primo piano che ha come scorciatoia ⌘[ / ⌘] (Safari, Finder, Chrome, Mail…) o
  ⌃- / ⌃⇧- (VS Code e simili), trovandola dalla scorciatoia e non dal nome (la ricerca è memorizzata per app).
  Se l'app non ha quella voce invia un vero tasto mouse indietro/avanti (Chrome, Firefox, Electron, JetBrains);
  in Xcode usa ⌃⌘← / ⌃⌘→.
- **Browser**: apri link in nuova scheda (⌘-clic sotto il puntatore), ricarica, nuova/chiudi/riapri scheda, scheda successiva/precedente.
- **Edit**: copia, incolla, taglia, annulla, ripristina, zoom.
- **System**: Mission Control, finestre dell'app, mostra Scrivania, Spotlight, screenshot, schermo intero, blocca schermo.
- **Media**: play/pausa, brano successivo/precedente, volume, muto.
| Chiave | Significato |
|---|---|
| `reverseScroll` | Inverte lo scroll **solo delle rotelline** (trackpad e Magic Mouse restano "naturali"). |
| `dragModifier` | Modificatori + trascinamento sinistro = sposta finestra; + destro = ridimensiona. Su una finestra in tiling: rilasciarla su un'altra le scambia, il resize sposta la divisione master/stack. |
| `buttons` | Tasto mouse (2 = centrale, 3 = indietro, 4 = avanti, …) con `modifiers` opzionali → azione (`none` lo disattiva). |

### Tiling
Layout per schermo: `tall` (master a sinistra), `wide` (master in alto), `columns`, `monocle`.
Gestisce solo le finestre standard; dialog, pannelli e finestre a schermo intero sono ignorati.
`floating` elenca i bundle ID da non affiancare.

### Azioni
| Azione | |
|---|---|
| `focus left\|right\|up\|down` | Sposta il focus alla finestra più vicina in quella direzione |
| `swap left\|right\|up\|down` | Scambia la finestra con la vicina (anche tra monitor) |
| `swap master` | Porta la finestra in posizione master |
| `layout tall\|wide\|columns\|monocle\|next` | Cambia layout dello schermo attivo |
| `ratio +0.05` / `ratio -0.05` | Ridimensiona l'area master |
| `float` | Finestra corrente floating ↔ tiling |
| `tiling` | Attiva/disattiva il tiling |
| `retile` | Ricalcola subito il layout |
| `display next` | Sposta la finestra sul monitor successivo |
| `launch <Nome App o bundle id>` | Apre/attiva un'app |
| `shell <comando>` | Esegue un comando con `/bin/sh -c` |
| `key <combo>` | Invia una combinazione di tasti (es. `key cmd+shift+4`). I simboli (`-`, `=`, `,`…) usano il tasto che li scrive nel layout attivo; simboli che il layout scrive solo con ⌥ (es. `[` sulla tastiera italiana) non sono affidabili come scorciatoia |
| `reload` | Ricarica la config |
| `none` | Non fa nulla: disattiva il tasto o il pulsante a cui è legata |
| `navigate back\|forward` | Indietro/avanti con la scorciatoia dell'app in primo piano |
| `system mission_control\|app_windows\|show_desktop` | Mission Control, finestre dell'app, mostra Scrivania (via Dock) |
| `media play_pause\|next\|previous\|volume_up\|volume_down\|mute` | Tasti multimediali |
| `click <modificatori>` | Clic sinistro sotto il puntatore con modificatori (es. `click cmd`) |

## Architettura

```
Sources/HyperSpace/
├── App/        AppDelegate (wiring, permesso), StatusMenu (menu bar)
├── Settings/   finestra Impostazioni (schede Keyboard/Mouse, SwiftUI caricato solo quando aperta)
├── Core/       EventTap, Config/ConfigStore, Action/ActionRunner, KeyCodes, Permissions
├── Keyboard/   KeyboardRemapper (UserKeyMapping per tastiera), KeyEmitter (eventi sintetici)
├── Mouse/      DragController (ponte tap → window manager)
└── Tiling/     WindowManager, AppWatcher (AXObserver), Layout, AX helpers
```

Scelte fatte per prestazioni e permessi minimi:

- **Un solo event tap attivo** (`CGEventTap` a livello HID) condiviso da tastiera e mouse, su un **thread dedicato**
  ad alta priorità: il lavoro sulle finestre (main thread) non può mai rallentare l'input.
  Un tap attivo richiede solo Accessibilità (un tap passivo richiederebbe Input Monitoring).
- **Si iscrive solo agli eventi usati.** I movimenti del mouse non vengono mai intercettati; lo scroll solo se
  `reverseScroll` è attivo; con una config vuota il tap non viene proprio installato.
- **Hot path senza allocazioni né lock**: le binding sono compilate in tabelle `[Int16]` indicizzate da
  `keyCode << 4 | modificatori`; la config passa al thread del tap con `CFRunLoopPerformBlock`.
- **Remap e hyper key nel layer HID**, per singola tastiera via `IOHIDServiceClient` (niente processi `hidutil`): zero CPU, nessun permesso; nuove tastiere rilevate con notifiche IOKit.
- **Tiling event-driven**: `AXObserver` per app + notifiche `NSWorkspace`, nessun polling. Le raffiche di
  eventi vengono accorpate in un solo retile; visibilità e posizione delle finestre arrivano da una sola
  chiamata `CGWindowListCopyWindowInfo` (senza titoli → niente Screen Recording) e le finestre vengono
  spostate solo se la loro posizione è effettivamente diversa.
- **Drag a 1000 Hz senza backlog**: il tap tiene solo l'ultima posizione e c'è al massimo un aggiornamento
  in coda sul main thread.
- **Timeout AX a 0,5 s** per app: un'app bloccata non congela il window manager.
- Config osservata con un `DispatchSource` kqueue: nessun costo finché il file non cambia.

### Limiti noti
- Usa la funzione privata (ma stabile da anni) `_AXUIElementGetWindow`, come yabai/Amethyst/Rectangle:
  l'app non può essere sandboxed né andare sul Mac App Store (vale per qualsiasi window manager via AX).
- Gli Spaces non vengono creati/gestiti: si affiancano le finestre dello Space visibile su ciascun monitor.

