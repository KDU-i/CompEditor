// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation

@main struct RealAssistanceTests {
    static func main() async {
        do { try await run() }
        catch { LSPProcesses.shared.stopAll(); print("FAIL REAL assistance: \(error)"); exit(1) }
    }
    static func run() async throws {
        setbuf(stdout, nil)
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        for language in LSPLanguage.allCases {
            let workspace = root.appendingPathComponent(language.rawValue)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let uri = workspace.appendingPathComponent(language == .java ? "Demo.java" : "probe.py")
            let baseline = language == .java ? "public class Demo { Demo(int count, String label) {} int add(int left, int right) { return left + right; } void use() { int result = add(1, 2); Demo x = new Demo(2, \"label\"); } }" : "def add(left: int, right: int) -> int:\n    return left + right\nresult = add(1, 2)\n"
            try baseline.write(to: uri, atomically: true, encoding: .utf8)
            let server = try LSPBundledServers.server(language, resources: app.appendingPathComponent("Contents/Resources"), storage: root.appendingPathComponent(language.rawValue + "-storage"))
            let helperURI = workspace.appendingPathComponent("helpers.py")
            if language == .python { try "class HelperWidget:\n    pass\n".write(to: helperURI, atomically: true, encoding: .utf8) }
            let peerURI = workspace.appendingPathComponent("Peer.java")
            if language == .java { try "public class Peer { static int shared(int value) { return value; } }".write(to: peerURI, atomically: true, encoding: .utf8) }
            let client = LSPClient()
            do {
                try await client.start(server, workspace: workspace)
                let caps = await client.capabilities
                try JSONEncoder().encode(caps).write(to: workspace.appendingPathComponent("Capabilities.json"))
                print("REAL \(language.rawValue) capabilities definition=\(caps["definitionProvider"]) signatures=\(caps["signatureHelpProvider"]) codeActions=\(caps["codeActionProvider"])")
                let definitionOffset = (baseline as NSString).range(of: "add(1").location
                let definition = try await client.definition(uri: uri, language: language, text: baseline, offset: definitionOffset)
                print("REAL \(language.rawValue) definition \(definition)")
                guard let location = LSPAssistance.locations(definition).first, location.uri == uri,
                      let range = try? LSPText.range(location.range, in: baseline), (baseline as NSString).substring(with: range).contains("add") else { throw LSPError.server("Actual definition missing") }
                print("PASS REAL \(language.rawValue): actual local method definition range")
                let call = (baseline as NSString).range(of: "add(1, ")
                let hint = try await client.signatures(uri: uri, language: language, text: baseline, offset: NSMaxRange(call))
                print("REAL \(language.rawValue) signature \(hint)")
                guard let signature = LSPAssistance.signature(hint), let active = signature.active,
                      (signature.label as NSString).substring(with: active).contains("right") else { throw LSPError.server("Actual second active parameter missing") }
                print("PASS REAL \(language.rawValue): active second argument label/type supplied by server")
                let bad = baseline.replacingOccurrences(of: "add(1, 2)", with: "add(\"wrong\", 2)")
                try await client.synchronizeDocument(uri: uri, language: language, text: bad)
                var diagnostics: LSPDiagnosticBatch?
                for _ in 0..<100 {
                    if let batch = await client.diagnostics(for: uri), batch.snapshot == bad, batch.items.contains(where: { $0["severity"].int == 1 }) { diagnostics = batch; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let diagnostics else { print("REAL rejected/absent diagnostic notification: \(await client.lastDiagnosticNotification)"); throw LSPError.server("No actual versioned error diagnostic") }
                print("PASS REAL \(language.rawValue): versioned error diagnostics \(diagnostics.version) \(diagnostics.items)")
                try JSONEncoder().encode(diagnostics.items).write(to: workspace.appendingPathComponent("Diagnostics.json"))
                try await client.synchronizeDocument(uri: uri, language: language, text: baseline)
                var cleared = false
                for _ in 0..<100 {
                    if let batch = await client.diagnostics(for: uri), batch.snapshot == baseline, !batch.items.contains(where: { $0["severity"].int == 1 }) { cleared = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard cleared else { throw LSPError.server("Actual diagnostic did not clear after unsaved correction") }
                print("PASS REAL \(language.rawValue): diagnostics clear on current unsaved version; old snapshot rejected")
                if language == .python {
                    try await client.synchronizeDocument(uri: helperURI, language: .python, text: "class HelperWidget:\n    pass\n")
                    for _ in 0..<30 {
                        if await client.diagnostics(for: helperURI) != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                let warningText = language == .java ? "public class Demo { private int unused; }" : "# pyright: reportUnusedImport=warning\nimport math\n"
                try await client.synchronizeDocument(uri: uri, language: language, text: warningText)
                var hasWarning = false
                for _ in 0..<100 {
                    if let batch = await client.diagnostics(for: uri), batch.snapshot == warningText, batch.items.contains(where: { $0["severity"].int == 2 }) { hasWarning = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard hasWarning else { throw LSPError.server("No actual warning diagnostic") }
                print("PASS REAL \(language.rawValue): actual severity2 warning for current unsaved buffer")
                let importText = language == .java ? "public class Demo { ArrayList<String> values; }" : "HelperWidget\n"
                let name = language == .java ? "ArrayList" : "HelperWidget"
                let symbol = (importText as NSString).range(of: name)
                let caret = NSMaxRange(symbol)
                let actions = try await client.codeActions(uri: uri, language: language, text: importText, range: symbol)
                let completions = try await client.complete(uri: uri, language: language, text: importText, caret: caret)
                print("REAL \(language.rawValue) import candidates \(completions.prefix(15))")
                var importEdits: [LSPText.Edit]?
                for item in completions.filter({ ($0["filterText"].string ?? $0["label"].string) == name || ($0["label"].string ?? "").hasPrefix(name) }).prefix(20) {
                    let resolved = try await client.resolve(item)
                    if let edits = try? LSPAssistance.importEdits(resolved, uri: uri, version: await client.version(of: uri), text: importText, symbol: symbol, caret: caret) { importEdits = edits; break }
                }
                print("REAL \(language.rawValue) actions \(actions)")
                var safeActions = 0
                for action in actions {
                    let resolved = try await client.resolveAction(action)
                    if let edits = try? LSPAssistance.actionEdits(resolved, uri: uri, version: await client.version(of: uri), text: importText) { safeActions += 1; if importEdits == nil && edits.contains(where: { $0.text.contains("import ") }) { importEdits = edits } }
                }
                guard let importEdits else { throw LSPError.server("No actual safe import assistance") }
                let imported = NSMutableString(string: importText)
                for edit in importEdits.reversed() { imported.replaceCharacters(in: edit.range, with: edit.text) }
                guard (imported as String).contains(language == .java ? "import java.util.ArrayList" : "from helpers import HelperWidget") else { throw LSPError.server("Wrong real server import") }
                print("PASS REAL \(language.rawValue): actual server import edits; \(safeActions) safe current-document code actions (unsupported commands not executed)")
                try (imported as String).write(to: workspace.appendingPathComponent("AppliedImport.txt"), atomically: true, encoding: .utf8)
                let crossText = language == .java ? "public class Demo { void use() { Peer.shared(1); } }" : "import helpers\nitem = helpers.HelperWidget()\n"
                let crossName = language == .java ? "shared" : "HelperWidget"
                let crossOffset = (crossText as NSString).range(of: crossName).location
                let crossDefinition = try await client.definition(uri: uri, language: language, text: crossText, offset: crossOffset)
                print("REAL \(language.rawValue) cross-file definition \(crossDefinition)")
                let expectedURL = language == .java ? peerURI : helperURI
                if let location = LSPAssistance.locations(crossDefinition).first {
                    print("REAL \(language.rawValue) definition guard: expectedURI=\(location.uri == expectedURL), inWorkspace=\(location.uri.standardizedFileURL.path.hasPrefix(workspace.standardizedFileURL.path + "/")), noSymlink=\(location.uri.standardizedFileURL.resolvingSymlinksInPath() == location.uri.standardizedFileURL)")
                }
                guard let location = LSPAssistance.locations(crossDefinition).first, location.uri == expectedURL, LSPAssistance.safeDefinitionFile(location.uri, workspace: workspace) == expectedURL.standardizedFileURL else { throw LSPError.server("Cross-file safe source definition missing") }
                print("PASS REAL \(language.rawValue): cross-file definition target inside safe workspace")
                guard try String(contentsOf: uri, encoding: .utf8) == baseline else { throw LSPError.server("Feature probes altered disk source") }
                if language == .python { await client.close(helperURI) }
                if language == .java {
                    let failedVersion = (await client.version(of: uri) ?? 0) + 1
                    try await client.notify("textDocument/didChange", .object([
                        "textDocument": .object(["uri": .string(uri.absoluteString), "version": .number(failedVersion)]),
                        "contentChanges": .array([.object(["range": .object(["start": .object(["line": .number(99999), "character": .number(0)]), "end": .object(["line": .number(99999), "character": .number(1)])]), "text": .string("invalid test edit")])])
                    ]))
                    try await Task.sleep(for: .seconds(3))
                    guard await client.lastDiagnosticNotification["version"].int != failedVersion else { throw LSPError.server("JDT patch labeled failed synchronization as current") }
                    print("PASS REAL java: injected invalid-range synchronization never published the failed version")
                }
                await client.close(uri); await client.stop()
            } catch { await client.stop(); LSPProcesses.shared.stopAll(); throw error }
        }
        LSPProcesses.shared.stopAll()
        print("Actual Java/Python assistance acceptance passed. No GUI automation performed.")
    }
}
