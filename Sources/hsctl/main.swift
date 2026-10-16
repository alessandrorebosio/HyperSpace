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
  completion zsh  print the zsh completion: eval "$(hsctl completion zsh)" in ~/.zshrc

window manager: every AeroSpace command, as with the `aerospace` CLI, e.g.
  workspace 2 | move-node-to-workspace Develop | focus left | layout tiles accordion
  list-windows --all --format '%{window-id} | %{app-name} | %{workspace}'
  list-workspaces --all | list-monitors | list-modes | list-apps
"""

if args.isEmpty || args == ["-h"] || args == ["--help"] {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}

// Answered here: it works without HyperSpace running.
if args == ["completion", "zsh"] {
    print(zshCompletion)
    exit(0)
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
