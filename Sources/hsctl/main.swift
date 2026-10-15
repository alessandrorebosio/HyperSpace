import Foundation
import HyperSpaceIPC

let args = Array(CommandLine.arguments.dropFirst())

let usage = """
usage: hsctl <command>
  status        show permissions and config state
  enable        turn remapping on
  disable       turn remapping off (HyperSpace stays open)
  toggle        switch between enabled and disabled
  do <action>   perform an action now, e.g. `hsctl do volume.up`, `hsctl do mission.control`
  reload        reload the config file
  config-path   print the config directory (keyboard.toml, mouse.toml, wm.toml)
  apps          list running apps with their bundle id (for per-app rules)
  version       print HyperSpace's version

window manager (same commands as AeroSpace):
  list-workspaces                     workspaces and their windows (* focused, + visible)
  list-windows                        windows, their workspace and state (* focused)
  focus|move|join-with left|right|up|down
  workspace <name>|next|prev          workspace-back-and-forth
  move-node-to-workspace <name>|next|prev [--focus-follows-window]
  layout tiles|accordion|horizontal|vertical|h_tiles|v_tiles|h_accordion|v_accordion|tiling|floating
  resize smart|width|height [+|-]<n>  balance-sizes  flatten-workspace-tree
  fullscreen [on|off]                 close
  focus-monitor|move-node-to-monitor|move-workspace-to-monitor left|right|up|down|next|prev
"""

if args.isEmpty || args == ["-h"] || args == ["--help"] {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}

switch IPCClient.send(IPC.Request(args: args)) {
case let .success(response):
    if !response.stdout.isEmpty { print(response.stdout) }
    if !response.stderr.isEmpty { FileHandle.standardError.write(Data((response.stderr + "\n").utf8)) }
    exit(response.exitCode)
case .failure(.notRunning):
    FileHandle.standardError.write(Data("hsctl: HyperSpace is not running\n".utf8))
    exit(2)
case let .failure(error):
    FileHandle.standardError.write(Data("hsctl: communication with HyperSpace failed (\(error))\n".utf8))
    exit(3)
}
