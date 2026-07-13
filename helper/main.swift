import Foundation
import HelperShared

// `--print-tree-hash <dir>`: not part of the XPC service — a build-time-only tool mode so
// `build/package-app.sh` can compute `GeneratedCLIManifest.expectedTreeHashHex` using the exact
// same compiled `computeTreeHash` that `HelperService.stageCLI` later verifies against,
// eliminating any risk of a shell-vs-Swift hashing mismatch. Never reached by the installed
// daemon in normal operation (launchd invokes this binary with no arguments).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--print-tree-hash" {
    guard let hash = computeTreeHash(at: URL(fileURLWithPath: CommandLine.arguments[2])) else {
        FileHandle.standardError.write(Data("print-tree-hash: failed to hash \(CommandLine.arguments[2])\n".utf8))
        exit(1)
    }
    print(hash)
    exit(0)
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard verifyClientIdentity(pid: connection.processIdentifier, expectedIdentifier: "com.khr898.ntfsmac") else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = HelperService(runner: RealCommandRunner())
        connection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
