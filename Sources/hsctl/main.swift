import Foundation
import HyperSpaceIPC

let args = Array(CommandLine.arguments.dropFirst())

let usage = """
usage: hsctl <command>
  status        show permissions and config state
  reload        reload the config file
  config-path   print the config file path
  apps          list running apps with their bundle id (for per-app rules)
  version       print HyperSpace's version
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
