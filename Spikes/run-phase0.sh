#!/bin/zsh
# Interactive phase 0 run. Writes everything to phase0.log next to this script.
# Run it from Terminal (not from an IDE) after quitting Karabiner-Elements and LinearMouse.
set -u
cd "${0:A:h}"
swift build -q || exit 1
B=.build/debug/helm-spike
LOG=phase0.log
: > $LOG

step() {
  print -P "\n%B== $1%b"
  print "== $1" >> $LOG
  [[ -n "${2:-}" ]] && { print "$2"; read -r "?Press Enter to start... " }
}
run() { "$@" 2>&1 | tee -a $LOG }

trap '$B capslock clear >/dev/null 2>&1' EXIT INT TERM

step "perms"
run $B perms

step "tap (active, remapping)" "For 40s: press both side buttons in Safari (should go back/forward),
hold Caps Lock + h/j/k/l (arrows), Caps + another key (normal key), tap Caps alone,
scroll the wheel up/down and left/right."
run $B capslock set
run $B tap 40 --remap
run $B capslock clear

step "hidpp (Logitech, no permissions expected)" "For 20s: press middle, back, forward and the DPI button on top."
run $B hidpp 20

step "hid (raw HID values)" "For 15s: press every mouse button and scroll."
run $B hid 15

step "ax (window enumeration)"
run $B ax

print "\nDone. Results are in $PWD/$LOG"
