#!/bin/zsh
# Interactive phase 0 run. Appends everything to phase0.log next to this script.
# Run it from a terminal app that has Accessibility, after quitting Karabiner-Elements and LinearMouse.
#   ./run-phase0.sh            all steps
#   ./run-phase0.sh tap ax     only some steps (perms, tap, hidpp, hid, ax)
set -u
cd "${0:A:h}"
swift build -q || exit 1
B=.build/debug/helm-spike
LOG=phase0.log
STEPS=(${@:-perms tap hidpp hid ax})

wants() { (( ${STEPS[(Ie)$1]} )) }

step() {
  print -P "\n%B== $1%b"
  print "\n== $1 ($(date +%T))" >> $LOG
  [[ -n "${2:-}" ]] && { print "$2"; read -r "?Press Enter to start... " }
}
run() { "$@" 2>&1 | tee -a $LOG }

needs_accessibility() {
  if ! $B perms | grep -q "AXIsProcessTrusted *= true"; then
    print -P "%F{red}This terminal app ($TERM_PROGRAM) has no Accessibility permission.%f"
    print "System Settings > Privacy & Security > Accessibility: enable it, quit and reopen the terminal, then run: $0 $1"
    print "SKIPPED $1: no Accessibility" >> $LOG
    return 1
  fi
}

trap '$B capslock clear >/dev/null 2>&1' EXIT INT TERM

if wants perms; then
  step "perms"
  run $B perms
fi

if wants tap && needs_accessibility tap; then
  step "tap (active, remapping)" "For 40s, KEYBOARD and MOUSE:
  - hold Caps Lock + h / j / k / l     -> should move like the arrow keys
  - hold Caps Lock + another key       -> should type that key normally
  - tap Caps Lock alone                -> should do nothing (no caps lock)
  - in Safari, press the side buttons  -> back / forward
  - scroll the wheel up/down and left/right"
  run $B capslock set
  run $B tap 40 --remap
  run $B capslock clear
fi

if wants hidpp; then
  step "hidpp (Logitech, no permissions expected)" "For 20s: press middle, back, forward and the DPI button (below the wheel)."
  run $B hidpp 20
fi

if wants hid; then
  step "hid (raw HID values)" "For 15s: press every mouse button and scroll."
  run $B hid 15
fi

if wants ax && needs_accessibility ax; then
  step "ax (window enumeration)"
  run $B ax
fi

print "\nDone. Results are in $PWD/$LOG"
