import Foundation
import HelmIPC

let args = Array(CommandLine.arguments.dropFirst())

let usage = """
usage: helmctl <command>
  status        show permissions and config state
  reload        reload the config file
  config-path   print the config file path
  version       print Helm's version
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
    FileHandle.standardError.write(Data("helmctl: Helm is not running\n".utf8))
    exit(2)
case let .failure(error):
    FileHandle.standardError.write(Data("helmctl: communication with Helm failed (\(error))\n".utf8))
    exit(3)
}
