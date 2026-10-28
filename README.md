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

> **Firma stabile.** Con la firma ad-hoc (`-`) ogni rebuild cambia la firma e macOS invalida il permesso
> di Accessibilità (va rimosso e riaggiunto in Impostazioni). Per lo sviluppo crea un certificato
> self-signed "Code Signing" in *Accesso Portachiavi → Assistente Certificato → Crea un certificato*
> (es. `HyperSpace Dev`) e builda con:
>
> ```bash
> make app SIGN_IDENTITY="HyperSpace Dev"
> ```

## Configurazione

`~/.config/hyperspace/config.json` — creato al primo avvio, ricaricato automaticamente a ogni salvataggio.
Se il file ha un errore l'icona in menu bar diventa ⚠︎ e il menu mostra il messaggio; resta attiva l'ultima config valida.

```json
{
  "keyboard": {
    "hyperKey": "caps_lock",
    "remap": [ { "from": "right_option", "to": "escape" } ],
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
| `hyperKey` | Tasto che diventa **hyper** (`cmd+alt+ctrl+shift`) finché è premuto. Le combinazioni hyper non legate arrivano comunque alle app. |
| `remap` | Rimappature 1:1 tra tasti singoli, applicate dal driver HID (`hidutil`): costo zero a runtime. Ripristinate all'uscita. |
| `bindings` | Combinazione → azione. Modificatori: `cmd`, `alt`/`opt`, `ctrl`, `shift`, `hyper`, `meh` (alt+ctrl+shift). |

Nomi tasti: `a`–`z`, `0`–`9`, `f1`–`f20`, `return`, `escape`, `tab`, `space`, `delete`, `forward_delete`,
`left`/`right`/`up`/`down`, `home`, `end`, `page_up`, `page_down`, `minus`, `equal`, `left_bracket`,
`right_bracket`, `backslash`, `semicolon`, `quote`, `grave`, `comma`, `period`, `slash`, `section`,
`caps_lock`, `left_/right_` + `command`/`option`/`control`/`shift`.

### Mouse
| Chiave | Significato |
|---|---|
| `reverseScroll` | Inverte lo scroll **solo delle rotelline** (trackpad e Magic Mouse restano "naturali"). |
| `dragModifier` | Modificatori + trascinamento sinistro = sposta finestra; + destro = ridimensiona. Su una finestra in tiling: rilasciarla su un'altra le scambia, il resize sposta la divisione master/stack. |
| `buttons` | Tasto mouse (2 = centrale, 3 = indietro, 4 = avanti, …) con `modifiers` opzionali → azione. |

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
| `key <combo>` | Invia una combinazione di tasti (es. `key cmd+shift+4`) |
| `reload` | Ricarica la config |

## Architettura

```
Sources/HyperSpace/
├── App/        AppDelegate (wiring, permesso), StatusMenu (menu bar)
├── Core/       EventTap, Config/ConfigStore, Action/ActionRunner, KeyCodes, Permissions
├── Keyboard/   HIDKeyRemapper (hidutil), KeyEmitter (eventi sintetici)
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
- **Remap semplici e hyper key nel driver HID** via `hidutil`: zero CPU, nessun permesso.
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
- `remap` sovrascrive eventuali `UserKeyMapping` impostati a mano con `hidutil`.
