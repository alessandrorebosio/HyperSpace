import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())

/// First numeric argument, used as a duration in seconds.
func durationArg(default value: Double) -> Double {
    args.lazy.compactMap(Double.init).first ?? value
}

let usage = """
usage: helm-spike <command>
  perms                 print the TCC permission state of this process
  tap [secs] [--remap]  log keyboard/mouse/scroll events; --remap also tests
                        mouse back/forward -> cmd-[ / cmd-] and the F18 (Caps) layer
  capslock show|set|clear
                        L0: show / map Caps Lock -> F18 / remove the mapping
  hid [secs]            log raw HID input values from mice and Logitech devices
  hidpp [secs]          probe Logitech HID++ devices and list their controls;
                        with secs, divert every divertable control and log presses
  ax                    time AX window enumeration per app
"""

switch args.first {
case "perms": Perms.run()
case "tap": Tap.run(remap: args.contains("--remap"), duration: durationArg(default: 30))
case "capslock": CapsLock.run(args.dropFirst().first ?? "show")
case "hid": HIDRaw.run(duration: durationArg(default: 30))
case "hidpp": HIDPP.run(listen: args.lazy.compactMap(Double.init).first)
case "ax": AXSpike.run()
default:
    print(usage)
    exit(1)
}
