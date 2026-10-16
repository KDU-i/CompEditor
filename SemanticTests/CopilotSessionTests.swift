// Offline lifecycle tests: synthetic boolean state only, no credentials or OAuth.
import Foundation
@main struct CopilotSessionTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = URL.temporaryDirectory.appendingPathComponent("compeditor-session-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let stateURL = fixture.appendingPathComponent("synthetic-state.json")
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); print("PASS: " + message) }
        func makeClient(offline: Bool = false) async throws -> LSPClient {
            let client = LSPClient(processes: LSPProcesses())
            var arguments = [root.appendingPathComponent("SemanticTests/copilot_mock.py").path, "--session-state", stateURL.path]
            if offline { arguments.append("--offline") }
            try await client.start(.init(language: .python, executable: "/usr/bin/python3", arguments: arguments), workspace: fixture, copilot: true)
            return client
        }
        let initial = try await makeClient()
        let missing = try await initial.request("checkStatus", .object([:]))
        check(CopilotAccountState(missing) == .notSignedIn, "explicit missing authentication distinguished")
        let device = try await initial.request("signIn", .object([:]))
        let finish = CopilotInline.command(device["command"], name: "github.copilot.finishDeviceFlow")!
        _ = try await initial.request("workspace/executeCommand", finish)
        await initial.shutdownAndStop()
        var expectedHome: String?
        for iteration in 1...3 {
            let client = try await makeClient()
            let status = try await client.request("checkStatus", .object([:]))
            check(CopilotAccountState(status) == .authenticated, "authentication restored after normal exit/start \(iteration)")
            let info = try await client.request("test/session", .object([:]))
            if let expectedHome { check(info["homeHash"].string == expectedHome, "stable HOME across server restarts") }
            else { expectedHome = info["homeHash"].string }
            check(info["methods"]["textDocument/didOpen"].int == nil, "authentication checking sends no documents")
            await client.shutdownAndStop()
            check(!(await client.isRunning()), "graceful shutdown exits owned server")
            do { try await client.synchronizeDocument(uri: fixture.appendingPathComponent("AfterOff.py"), language: .python, text: "synthetic")
                preconditionFailure("shutdown synchronized a document")
            } catch { print("PASS: shutdown stops document synchronization") }
        }
        let offline = try await makeClient(offline: true)
        do { _ = try await offline.request("checkStatus", .object([:])); preconditionFailure("offline accepted") }
        catch { print("PASS: offline state check fails without logging out") }
        await offline.shutdownAndStop()
        let restored = try await makeClient()
        let status = try await restored.request("checkStatus", .object([:]))
        check(CopilotAccountState(status) == .authenticated, "offline failure preserves synthetic authentication")
        let summary = try await restored.request("test/session", .object([:]))
        check(summary["methods"]["signOut"].int == nil, "normal close never invokes signOut")
        check(summary["methods"]["signIn"].int == 1, "restart checks avoid repeated signIn/device flow")
        _ = try await restored.request("signOut", .object([:]))
        await restored.shutdownAndStop()
        let signedOut = try await makeClient()
        let loggedOut = try await signedOut.request("checkStatus", .object([:]))
        check(CopilotAccountState(loggedOut) == .notSignedIn, "only explicit signOut clears authentication")
        await signedOut.shutdownAndStop()
        for value in [LSPJSON.null, .object(["status": .string("NetworkError")]), .object(["status": .string("Unknown")])] {
            check(CopilotAccountState(value) == .unknown, "unknown status is not logged out")
        }
        check(CopilotAccountState(.object(["status": .string("NotAuthorized")])) == .notAuthorized, "entitlement failure differs from signed out")
        let suite = "CompEditor.OfflineSessionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CopilotSessionPreferences(defaults: defaults)
        check(!settings.remembersContextConsent, "previous session consent is not silently persisted")
        settings.remembersContextConsent = true; settings.enabled = true
        let restartedSettings = CopilotSessionPreferences(defaults: UserDefaults(suiteName: suite)!)
        check(restartedSettings.remembersContextConsent && restartedSettings.enabled, "explicit remembered context consent survives restart")
        settings.enabled = false
        check(!restartedSettings.enabled && restartedSettings.remembersContextConsent, "explicit OFF survives restart without erasing consent/authentication")
        check(restartedSettings.automaticSuggestions && !restartedSettings.automaticNextEdits, "automatic settings have independent defaults")
        settings.automaticSuggestions = false; settings.automaticNextEdits = true
        let automaticRestart = CopilotSessionPreferences(defaults: UserDefaults(suiteName: suite)!)
        check(!automaticRestart.automaticSuggestions && automaticRestart.automaticNextEdits, "automatic inline and NES flags survive restart independently")
        let stored = defaults.persistentDomain(forName: suite)!
        check(stored.count == 4 && stored.values.allSatisfy { $0 is Bool || $0 is NSNumber }, "editor persists only four non-secret boolean preferences")
        print("All synthetic restart/consent tests passed. No credential storage accessed.")
    }
}
