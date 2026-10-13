// Read-only official authentication-state probe. No signIn, signOut, documents,
// device-flow commands, auth-file reads or raw response/error logging.
import Foundation
import CryptoKit
@main struct LiveCopilotSessionProbe {
    static func main() async {
        let server = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            let digest = SHA256.hash(data: try Data(contentsOf: server)).map { String(format: "%02x", $0) }.joined()
            guard digest == "fd94d41828e75ff29586a3d3b1029ff203f69fb4d947120a24979e6ac75c5df0" else { print("STOP: official executable checksum mismatch"); return }
        } catch { print("STOP: executable unavailable"); return }
        for cycle in 1...3 {
            let client = LSPClient(processes: LSPProcesses())
            do {
                try await client.start(.init(language: .python, executable: server.path, arguments: ["--stdio"]), workspace: .temporaryDirectory, copilot: true)
                let response = try await client.request("checkStatus", .object([:]))
                let state = CopilotAccountState(response)
                print("Cycle \(cycle): \(state). No source document synchronized.")
                await client.shutdownAndStop()
                print("Cycle \(cycle): owned server exited = \(!(await client.isRunning()))")
                guard state == .authenticated else { print("STOP: existing authentication not confirmed; no new OAuth flow attempted."); return }
            } catch LSPError.methodNotFound {
                await client.shutdownAndStop()
                print("STOP: pinned server does not support the official-client status method; no signIn fallback attempted."); return
            } catch {
                await client.shutdownAndStop()
                print("STOP: status check failed; no credentials or raw errors logged and no OAuth attempted."); return
            }
        }
        print("PASS: existing official authentication reused across three independent server starts.")
    }
}
