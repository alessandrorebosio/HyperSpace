# Tessera — Mini progettazione

> Un'unica app macOS, leggera e con il minimo dei permessi, che unisce:
> - **remapping tastiera** (alla Karabiner-Elements)
> - **remapping/scroll mouse**, incluso Logitech (alla LinearMouse)
> - **tiling window manager** (alla AeroSpace)

Stato: bozza da approvare prima di scrivere codice.

---

## 1. Obiettivi e non-obiettivi

**Obiettivi**
- Un solo processo, una sola app in menu bar (`LSUIElement`), nessun Dock icon.
- **Un solo permesso TCC: Accessibilità.** Nessun driver, nessun daemon root, nessuna password admin.
- Latenza aggiunta per evento input < 1 ms, CPU ~0% a riposo, RAM < 30 MB.
- Configurazione testuale (TOML) con hot-reload, versionabile in dotfiles.
- Avvio al login tramite `SMAppService.mainApp` (nessun LaunchAgent manuale).

**Non-obiettivi (almeno v1)**
- Niente Virtual HID driver (DriverKit) come Karabiner → è la fonte principale di permessi e complessità.
- Niente GUI di editing complessa: UI minima (stato, permessi, reload, errori config).
- Niente supporto a protocolli proprietari Logitech (HID++) in v1 — vedi §5.3.
- Niente disattivazione SIP, niente scripting addition (AeroSpace non ne usa, noi neanche).

---

## 2. Come funzionano i tre progetti di riferimento (e cosa prendiamo)

| Progetto | Tecnica | Permessi | Cosa prendiamo |
|---|---|---|---|
| **Karabiner-Elements** | Daemon root che fa *seize* dei device HID via IOKit + driver DriverKit che emula una tastiera virtuale | Input Monitoring, estensione di sistema, admin | Il **modello delle regole** (from → to, to_if_alone, simultaneous, condizioni per app). **Non** l'architettura. |
| **LinearMouse** | `CGEventTap` su eventi mouse/scroll + IOHIDManager per capire da quale device arriva l'evento | Accessibilità | Pipeline eventi mouse, configurazione **per device**, scroll lineare/invertito. |
| **AeroSpace** | API Accessibility (`AXUIElement`) + workspace "virtuali" (finestre nascoste spostandole fuori schermo), albero di tiling i3-like, config TOML, CLI | Accessibilità | Quasi tutto il modello WM: albero, workspace virtuali, comandi, formato config. |

Licenze: verificare prima di copiare codice (AeroSpace e LinearMouse MIT, Karabiner-Elements Unlicense). Mantenere attribuzioni in `THIRD_PARTY.md`.

---

## 3. Strategia "minimi permessi" — il punto chiave

Separiamo il remapping in **tre livelli**, scegliendo sempre il più basso che basta:

| Livello | Meccanismo | Permessi | Uso |
|---|---|---|---|
| **L0 — HID key mapping** | `IOHIDEventSystemClient` property `UserKeyMapping` (la stessa cosa che fa `hidutil`) | **Nessuno** | Remap 1:1 statici: CapsLock→Esc, swap ⌘/⌥ su tastiera esterna, ecc. Gira nel kernel, costo zero, funziona anche nei campi password. Filtrabile per device (VendorID/ProductID). |
| **L1 — Event tap** | `CGEventTap` attivo (`kCGSessionEventTap`, head insert) | **Accessibilità** | Remap complessi: dual-role (Caps = Esc se premuto da solo, Ctrl se tenuto), layer, combo, regole per app, tasti mouse, scroll, hotkey del WM. |
| **L2 — Accessibility API** | `AXUIElement` + `AXObserver` | **Accessibilità** (stesso permesso) | Window manager. |

Risultato: **un solo permesso (Accessibilità)**, e se l'utente usa solo remap semplici, **zero permessi**.

Hotkey del WM: passano nello stesso event tap di L1 (un solo tap per tastiera, niente Carbon `RegisterEventHotKey` duplicato).

### Limiti noti di questa scelta (accettati consapevolmente)
- **Secure Input** (campi password, Terminal con "Secure Keyboard Entry"): il tap L1 non vede i tasti. Mitigazione: i remap critici (es. CapsLock) vanno in L0, che funziona sempre.
- Un `CGEventTap` vede eventi già "tradotti" da macOS: alcuni tasti speciali (fn/Globe, tasti media) sono più limitati rispetto a Karabiner.
- Se il tap è lento, macOS lo disattiva (`kCGEventTapDisabledByTimeout`) → va riattivato e il callback deve essere minimale.

---

## 4. Architettura

```
┌──────────────────────── Tessera.app (un processo) ─────────────────────────┐
│                                                                              │
│  Main thread (UI)            Input thread (RT, QoS userInteractive)          │
│  ┌──────────────┐            ┌─────────────────────────────────────────┐     │
│  │ MenuBar/UI   │            │ CGEventTap ──► EventPipeline             │     │
│  │ Permissions  │            │   ├─ KeyEngine   (regole compilate)      │     │
│  │ ConfigLoader │──snapshot─►│   ├─ MouseEngine (per-device, scroll)    │     │
│  │ (FSEvents)   │  immutab.  │   └─ HotkeyRouter ──► WM command queue ──┼──┐  │
│  └──────────────┘            └─────────────────────────────────────────┘  │  │
│         │                                                                  │  │
│         ▼                    WM actor (thread dedicato)                    │  │
│  ┌──────────────┐            ┌─────────────────────────────────────────┐  │  │
│  │ HIDMapper L0 │            │ WindowManager: albero, workspace,        │◄─┘  │
│  │ (no perms)   │            │ layout, AXObserver per app               │     │
│  └──────────────┘            └─────────────────────────────────────────┘     │
│                                         ▲                                    │
│                         Unix socket ────┘  (CLI `tessera`, opzionale)        │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Moduli (Swift Package, target separati)

| Target | Responsabilità | Dipende da |
|---|---|---|
| `TesseraCore` | Modelli config, parser TOML, validazione, logging (`os.Logger`), permessi | — |
| `KeyEngine` | Compila le regole in tabelle di lookup; macchina a stati per dual-role/layer/combo | Core |
| `MouseEngine` | Remap pulsanti, scroll (inversione, linearizzazione, velocità) per device | Core |
| `HIDMapper` | Applica/rimuove `UserKeyMapping` L0 per device | Core, IOKit |
| `InputTap` | Gestione `CGEventTap`, thread dedicato, riattivazione su timeout | Key/MouseEngine |
| `WindowManager` | Albero tiling, workspace virtuali, comandi, osservazione finestre AX | Core |
| `TesseraApp` | App menu bar, onboarding permessi, login item | tutti |
| `tessera` (CLI) | Client socket per comandi WM e `reload` | Core |

### Principi di performance
- **Config compilata**: il callback del tap non legge TOML/dizionari; usa array indicizzati per keycode (`[UInt16: Action]` → array fisso da 256 slot).
- **Snapshot immutabili**: la config viene sostituita atomicamente (swap di riferimento), nessun lock nel percorso caldo.
- **Zero allocazioni** nel callback dove possibile; niente log sincroni nel percorso caldo.
- **Il WM non gira mai nel callback**: l'hotkey accoda un comando e il tap ritorna subito. Le chiamate AX (lente, possono bloccare) stanno sul loro thread.
- Nessun polling: tutto event-driven (event tap, `AXObserver`, `NSWorkspace` notifications, FSEvents).

---

## 5. Funzionalità per modulo

### 5.1 Tastiera (v1)
- Remap semplice (→ L0 automaticamente se possibile)
- Dual-role / `to_if_alone` con timeout configurabile
- Layer (es. tenendo Space o Caps si attiva un layer hjkl→frecce)
- Combinazioni simultanee (es. `j+k` → Esc) — v1.1
- Condizioni: app in primo piano (bundle id), device (vendor/product id)

### 5.2 Mouse (v1)
- Remap pulsanti 3/4/5… → tasti, combinazioni o comandi WM
- Scroll: inversione separata per mouse/trackpad, scroll lineare, velocità/accelerazione per device
- Identificazione device via IOHIDManager (match dell'ultimo device attivo, come LinearMouse)

### 5.3 Logitech — punto da chiarire
- I pulsanti "standard" (back/forward, middle, rotella orizzontale) arrivano come normali eventi HID → **coperti dal v1**.
- Pulsante gesture, thumb wheel su alcuni modelli, DPI, SmartShift richiedono il protocollo proprietario **HID++** → serve aprire il device HID (potenziale permesso **Input Monitoring**) e implementare il protocollo per modello. **Rimandato a v2, opzionale e disattivato di default.** Prima uno spike per capire quali tasti del *tuo* mouse servono.

### 5.4 Window manager (v1, sottoinsieme di AeroSpace)
- Tiling ad albero (h/v split, accordion), focus/move/resize, float per app
- Workspace virtuali (no Spaces di macOS, niente SIP), assegnazione workspace per monitor
- Regole per app (es. Finder floating, Slack → workspace 9)
- Comandi richiamabili da hotkey e da CLI

---

## 6. Configurazione (bozza)

`~/.config/tessera/tessera.toml`, ricaricata automaticamente al salvataggio.

```toml
[keyboard]
simple = [
  { from = "caps_lock", to = "escape" },           # → L0, nessun permesso
]

[[keyboard.rule]]
from = "caps_lock"
to = "left_control"
to_if_alone = "escape"

[[keyboard.layer]]
trigger = "space"                 # tenuto = layer, premuto da solo = space
map = { h = "left_arrow", j = "down_arrow", k = "up_arrow", l = "right_arrow" }

[[mouse.device]]
match = { vendor = 0x046d }       # Logitech
scroll = { reverse = true, linear = true, lines = 3 }
buttons = { button4 = "cmd-[", button5 = "cmd-]" }

[wm]
enabled = true
gaps = { inner = 8, outer = 8 }

[wm.bindings]
"alt-h" = "focus left"
"alt-shift-h" = "move left"
"alt-1" = "workspace 1"
"alt-shift-1" = "move-node-to-workspace 1"

[[wm.rule]]
app = "com.apple.finder"
layout = "floating"
```

---

## 7. Stack tecnico

- **Swift 6** (strict concurrency), Swift Package Manager + piccolo progetto Xcode solo per bundle/firma.
- **AppKit** per menu bar e onboarding; SwiftUI solo per la finestra impostazioni.
- Target: **macOS 15+**.
- **Non sandboxed** (App Sandbox impedisce di controllare finestre di altre app via AX) → distribuzione fuori App Store, firmata Developer ID + notarizzata.
- Dipendenze esterne: solo un parser TOML (es. `TOMLKit`) — tutto il resto è framework di sistema.
- Test: unit test su KeyEngine/MouseEngine (pure, senza IO) e sull'algoritmo di layout del WM.

---

## 8. Roadmap

| Fase | Contenuto | Esito atteso |
|---|---|---|
| **0 — Spike** | Event tap minimale, `UserKeyMapping` via IOKit, enumerazione finestre AX, lettura device Logitech | Conferma limiti/permessi reali sul tuo Mac |
| **1 — Fondamenta** | Package, app menu bar, onboarding Accessibilità, config TOML + hot-reload, CLI | App che parte, chiede 1 permesso, ricarica config |
| **2 — Tastiera** | L0 + KeyEngine (remap, dual-role, layer, condizioni app) | Sostituisce il 90% dell'uso tipico di Karabiner |
| **3 — Mouse** | MouseEngine per-device, pulsanti, scroll | Sostituisce LinearMouse |
| **4 — WM** | Albero, workspace virtuali, comandi, regole | Sostituisce AeroSpace per uso quotidiano |
| **5 — Extra** | Combo simultanee, HID++ Logitech (opzionale), UI impostazioni | — |

---

## 9. Decisioni aperte

1. **Nome**: "Tessera" è provvisorio (tessere = tiling + tasti).
2. **Formato config**: TOML (come AeroSpace) vs JSON (come Karabiner, importabile). Proposta: TOML + importer per le regole semplici di Karabiner.
3. **Logitech**: quali pulsanti/modello? Determina se HID++ serve davvero.
4. **WM**: replicare AeroSpace 1:1 nei comandi (riuso config esistente) o sottoinsieme semplificato?
