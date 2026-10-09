// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
import Foundation

@main struct CoreTests {
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name)
        print("PASS: \(name)")
    }
    static func rejects(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError(name) } catch { print("PASS: \(name)") }
    }
    static func main() async throws {
        let suite = "SemanticTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = LSPSemanticPreferences(defaults: defaults)
        check(prefs.globallyEnabled && prefs.automatic && prefs.isEnabled(.java) && prefs.isEnabled(.python), "fresh profile requires no enable/config/folder steps")
        prefs.globallyEnabled = false; prefs.automatic = false; prefs.setEnabled(false, for: .java)
        let relaunched = LSPSemanticPreferences(defaults: defaults)
        check(!relaunched.globallyEnabled && !relaunched.automatic && !relaunched.isEnabled(.java) && relaunched.isEnabled(.python), "all toggle preferences survive reconstruction")
        defaults.removeObject(forKey: "semanticZeroSetupVersion")
        check(!LSPSemanticPreferences(defaults: defaults).automatic, "migration preserves previous explicit OFF")
        let temp = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("SemanticTestBuild/SemanticRouting-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let home = temp.appendingPathComponent("home"), cache = temp.appendingPathComponent("cache")
        let project = home.appendingPathComponent("Documents/Project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("pyproject.toml"))
        let file = project.appendingPathComponent("src/Probe.py")
        let saved = try LSPWorkspaceRouter.route(fileURL: file, bufferID: UUID(), language: .python, cache: cache, home: home)
        check(!saved.isolated && saved.workspace.path == project.resolvingSymlinksInPath().path, "bounded nearest project marker selected automatically")
        let standalone = try LSPWorkspaceRouter.route(fileURL: project.appendingPathComponent("src/Demo.java"), bufferID: UUID(), language: .java, cache: cache, home: home)
        check(!standalone.isolated && standalone.workspace.path == project.appendingPathComponent("src").resolvingSymlinksInPath().path, "no marker uses narrow containing folder")
        for path in [home.path, home.appendingPathComponent("Documents").path, home.appendingPathComponent("Library/Secrets").path, home.appendingPathComponent(".ssh").path, "/Volumes/TestVolume", "/usr/local/lib", "/opt/homebrew", "/private/var", "/Applications/Test.app/Contents"] {
            let route = try LSPWorkspaceRouter.route(fileURL: URL(fileURLWithPath: path).appendingPathComponent("Probe.py"), bufferID: UUID(), language: .python, cache: cache, home: home)
            check(route.isolated && route.uri.deletingLastPathComponent().path == route.workspace.path, "broad/sensitive root isolated: " + path)
        }
        let linkedTarget = temp.appendingPathComponent("outside.py")
        try Data("sensitive = 1".utf8).write(to: linkedTarget)
        let link = project.appendingPathComponent("src/link.py")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linkedTarget)
        let linked = try LSPWorkspaceRouter.route(fileURL: link, bufferID: UUID(), language: .python, cache: cache, home: home)
        check(linked.isolated && !FileManager.default.fileExists(atPath: linked.uri.path), "opened symlink target is synchronized only through isolated virtual URI")
        let buffer = UUID()
        let untitled = try LSPWorkspaceRouter.route(fileURL: nil, bufferID: buffer, language: .java, cache: cache, home: home)
        let repeated = try LSPWorkspaceRouter.route(fileURL: nil, bufferID: buffer, language: .java, cache: cache, home: home)
        check(untitled.isolated && untitled.uri == repeated.uri && !FileManager.default.fileExists(atPath: untitled.uri.path), "untitled has stable virtual URI without writing text")
        rejects("missing bundle resources fail closed") { _ = try LSPBundledServers.server(.python, resources: temp, storage: cache) }
        let resources = temp.appendingPathComponent("SemanticServers")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"launcher":"org.eclipse.equinox.launcher_../../escape.jar"}"#.utf8).write(to: resources.appendingPathComponent("manifest.json"))
        rejects("bundled manifest traversal refused") { _ = try LSPBundledServers.server(.java, resources: temp, storage: cache) }
        try FileManager.default.removeItem(at: resources)
        let outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: outside)
        rejects("whole bundled resource symlink escape refused") { _ = try LSPBundledServers.server(.python, resources: temp, storage: cache) }
        let lower: LSPJSON = .object(["label": .string("lower"), "insertText": .string("lower"), "sortText": .string("20")])
        let unrelated: LSPJSON = .object(["label": .string("upper"), "sortText": .string("00"), "preselect": .bool(true)])
        let exact = LSPPresentation.candidates([unrelated, lower], text: "obj.low", fallback: NSRange(location: 4, length: 3), caret: 7)
        check(exact.count == 1 && exact[0].item == lower && exact[0].ghost == "er", "typed prefix removed from compatible gray preview; irrelevant preselect filtered")
        let preselected: LSPJSON = .object(["label": .string("lowest"), "preselect": .bool(true), "sortText": .string("99")])
        check(LSPPresentation.candidates([lower, preselected], text: "obj.low", fallback: NSRange(location: 4, length: 3), caret: 7)[0].item == preselected, "server preselect wins equal relevance")
        let remapped: LSPJSON = .object(["label": .string("different display"), "insertText": .string("lower"), "filterText": .string("lower")])
        check(LSPPresentation.candidates([remapped], text: "obj.low", fallback: NSRange(location: 4, length: 3), caret: 7).count == 1, "server filterText drives matching instead of display label")
        check(LSPPresentation.ghost(edits: [.init(range: NSRange(location: 4, length: 3), text: "lower", primary: true)], text: "obj.low;", caret: 7) == nil, "preview never covers following source")
        check(LSPPresentation.ghost(edits: [.init(range: NSRange(location: 4, length: 3), text: "lower\nnext", primary: true)], text: "obj.low", caret: 7) == nil, "multiline preview suppressed")
        check(LSPPresentation.ghost(edits: [.init(range: NSRange(location: 0, length: 2), text: "😀x", primary: true)], text: "😀\r\nnext", caret: 2) == "x", "Unicode UTF16 prefix and CRLF preview boundary")
        check(LSPPresentation.ghost(edits: [.init(range: NSRange(location: 0, length: 2), text: "abx", primary: true)], text: "😀", caret: 2) == nil, "replacement-prefix mismatch suppressed")
        check(LSPPresentation.ghost(edits: [.init(range: NSRange(location: 0, length: 1), text: "ab", primary: true), .init(range: NSRange(location: 0, length: 0), text: "import")], text: "a", caret: 1) == nil, "additional edits never hidden behind append preview")
        check(LSPPresentation.ghost(edits: [.init(range: NSRange(location: 0, length: 2), text: "Z😀", primary: true)], text: "ab", caret: 2) == nil, "replacement surrogate split preview rejected")
        var policy = LSPDebouncePolicy()
        check(policy.delay(now: 1, warm: false) == 120 && policy.delay(now: 2, warm: true) == 60 && policy.delay(now: 2.05, warm: true) == 110, "adaptive cold/warm/rapid typing delays")
        check(LSPAutomaticContext.trigger(text: "obj.", caret: 4, characters: ["."])?.character == ".", "advertised automatic trigger")
        check(LSPAutomaticContext.trigger(text: "obj.", caret: 4, characters: []) == nil, "unadvertised trigger refused")
        for language in LSPLanguage.allCases {
            for prefix in ["l", "lo", "low"] {
                let text = "obj." + prefix
                let context = LSPAutomaticContext.trigger(text: text, caret: (text as NSString).length, characters: ["."])
                check(context != nil && context?.character == nil, "\(language.rawValue) \(prefix.count)-character identifier triggers semantic path")
            }
            check(LSPAutomaticContext.trigger(text: "obj.", caret: 4, characters: ["."])?.character == ".", "\(language.rawValue) dot needs no identifier prefix")
        }
        check(LSPAutomaticContext.trigger(text: "a", caret: 1, characters: []) != nil, "first root identifier character eligible")
        check(LSPAutomaticContext.trigger(text: "", caret: 0, characters: ["."]) == nil, "empty buffer never triggers unsolicited request")
        check(LSPAutomaticContext.trigger(text: ".", caret: 1, characters: ["."]) == nil, "receiverless dot never floods blank buffer")
        check(LSPAutomaticContext.trigger(text: "   .", caret: 4, characters: ["."]) == nil, "blank receiver dot refused")
        check(LSPAutomaticContext.trigger(text: "obj.low", caret: 7, characters: []) != nil, "three-character identifier eligible")
        check(LSPAutomaticContext.trigger(text: "123", caret: 3, characters: []) == nil, "numeric token not identifier")
        check(LSPAutomaticContext.trigger(text: "abc ", caret: 4, characters: []) == nil, "whitespace closes candidates")
        let largePrefix = String(repeating: " ", count: 100_000) + "obj.low"
        check(LSPAutomaticContext.trigger(text: largePrefix, caret: (largePrefix as NSString).length, characters: []) != nil, "large-document eligibility uses bounded suffix")
        let unicode = "α😀\r\nabc\n"
        let position = try LSPText.position(3, in: unicode)
        check(position["character"].int == 3, "UTF-16 non-BMP position")
        let crlf = try LSPText.offset(.object(["line":.number(1),"character":.number(2)]), in: unicode)
        check(crlf == 7, "CRLF position")
        rejects("reject surrogate-splitting edit") { _ = try LSPText.offset(.object(["line":.number(0),"character":.number(2)]), in: unicode) }
        rejects("reject invalid position") { _ = try LSPText.offset(.object(["line":.number(8),"character":.number(0)]), in: unicode) }
        let message: LSPJSON = .object(["label":.string("😀"), "progress":.decimal(0.5)])
        let packet = try LSPFramer.encode(message)
        var framer = LSPFramer(), decoded: [LSPJSON] = []
        for byte in packet + packet { decoded += try framer.append(Data([byte])) }
        check(decoded == [message,message], "fragmented and coalesced UTF-8 framing and decimal JSON")
        rejects("reject oversized framing") { var f = LSPFramer(); _ = try f.append(Data("Content-Length: 9000000\r\n\r\n".utf8)) }
        let source = "obj.le"
        let edit: LSPJSON = .object(["label":.string("length"),"textEdit":.object(["newText":.string("length"),"range":.object(["start":.object(["line":.number(0),"character":.number(4)]),"end":.object(["line":.number(0),"character":.number(6)])])])])
        let edits = try LSPText.edits(edit,text:source,fallback:NSRange(location:4,length:2),caret:6)
        check(edits.count == 1 && edits[0].range == NSRange(location:4,length:2), "server replacement range")
        rejects("reject snippet insertion") { _ = try LSPText.edits(.object(["label":.string("bad"),"insertTextFormat":.number(2)]),text:source,fallback:NSRange(location:4,length:2),caret:6) }
        rejects("reject server command") { _ = try LSPText.edits(.object(["label":.string("bad"),"command":.object([:])]),text:source,fallback:NSRange(location:4,length:2),caret:6) }
        let jdtItem: LSPJSON = .object(["label":.string("substring"),"command":.object(["command":.string("java.completion.onDidSelect")])])
        let jdtEdits = try LSPText.edits(jdtItem,text:source,fallback:NSRange(location:4,length:2),caret:6)
        check(jdtEdits[0].text == "substring", "JDT selection bookkeeping omitted while plain edit remains usable")
        let client = LSPClient()
        let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try await client.start(.init(language:.python,executable:"/usr/bin/python3",arguments:[root.appendingPathComponent("SemanticTests/mock_server.py").path]),workspace:root)
        let advertised = await client.triggerCharacters
        check(advertised == ["."], "mock advertised triggers preserved")
        let uri = root.appendingPathComponent("Unsaved.py")
        let first = try await client.complete(uri:uri,language:.python,text:"obj.le",caret:6)
        check(first.first?["detail"].string == "obj.le", "mock didOpen receives unsaved snapshot")
        let second = try await client.complete(uri:uri,language:.python,text:"obj.len",caret:7)
        check(second.first?["data"]["version"].int == 2, "mock incremental synchronization/version")
        let unchangedItems = try await client.complete(uri: uri, language: .python, text: "obj.len", caret: 7)
        check(unchangedItems.first?["data"]["version"].int == 2, "same snapshot requests skip redundant didChange/version")
        let triggered = try await client.complete(uri:uri,language:.python,text:"obj.",caret:4,trigger:".")
        check(triggered[0]["data"]["context"]["triggerKind"].int == 2 && triggered[0]["data"]["context"]["triggerCharacter"].string == ".", "mock automatic trigger context transmitted")
        let resolved = try await client.resolve(second[0])
        check(resolved == second[0], "mock completion resolve")
        for prefix in ["l", "le", "len"] {
            let text = "obj." + prefix
            let caret = (text as NSString).length
            let advertised = await client.triggerCharacters
            guard let context = LSPAutomaticContext.trigger(text: text, caret: caret, characters: advertised) else { fatalError("short mock prefix") }
            let items = try await client.complete(uri: uri, language: .python, text: text, caret: caret, trigger: context.character)
            let shown = LSPPresentation.candidates(items, text: text, fallback: NSRange(location: 4, length: prefix.count), caret: caret)
            check(items[0]["detail"].string == text && items[0]["data"]["context"]["triggerKind"].int == 1 && shown.first?.ghost != nil, "mock \(prefix.count)-character eligibility-to-request-to-box/ghost path")
        }
        let changingResolve: LSPJSON = .object(["label": .string("lower"), "data": .object(["resolveAddsEdit": .bool(true)])])
        let offered = LSPPresentation.candidates([changingResolve], text: "obj.low", fallback: NSRange(location: 4, length: 3), caret: 7)
        check(offered[0].ghost == "er", "unresolved mock item initially append-compatible")
        let changedResolve = try await client.resolve(changingResolve)
        let changedEdits = try LSPText.edits(changedResolve, text: "obj.low", fallback: NSRange(location: 4, length: 3), caret: 7)
        check(changedEdits.count == 2 && LSPPresentation.ghost(edits: changedEdits, text: "obj.low", caret: 7) == nil, "resolve-added import invalidates ghost promise but remains valid popup edit")
        let pointerSource = "😀\r\nprobe(count)"
        let symbol = LSPHoverPresentation.symbol(in: pointerSource, at: 6)!
        check(symbol == NSRange(location: 4, length: 5), "hover symbol offset respects non-BMP prefix and CRLF")
        check(LSPHoverPresentation.callOffset(in: pointerSource, symbol: symbol) == 10, "call signature location follows actual opening parenthesis")
        check(LSPHoverPresentation.symbol(in: "42 .", at: 0) == nil && LSPHoverPresentation.symbol(in: "probe ", at: 5) == nil, "numbers/whitespace never guessed as hover symbol")
        check(LSPHoverPresentation.symbol(in: "α_name", at: 1) == NSRange(location: 0, length: 6), "Unicode hover identifier range")
        check(LSPHoverPresentation.text(hover: .null) == nil, "no hover metadata produces no fabricated info")
        let hostile: LSPJSON = .object(["contents": .object(["kind": .string("markdown"), "value": .string("```java\nMap<T, U> make(int count)\n```\n<img src='https://invalid.test/x'> [link](command:run)\u{202E}")])])
        let safe = LSPHoverPresentation.text(hover: hostile)!
        check(safe.contains("Map<T, U>") && safe.contains("command:run") && !safe.contains("\u{202E}") && !safe.contains("```"), "hover is inert plain text; preserves generics; strips fences and bidi controls")
        let hugeHover: LSPJSON = .object(["contents": .string(String(repeating: "a", count: 10000))])
        check(LSPHoverPresentation.text(hover: hugeHover)!.utf16.count <= 4096, "hover display size bounded")
        check(LSPHoverPresentation.symbol(in: "𝒜name", at: 1) == NSRange(location: 0, length: 6), "supplementary identifier handles low-surrogate pointer offset")
        check(LSPHoverPresentation.symbol(in: "e\u{301}_name", at: 1) == NSRange(location: 0, length: 7), "composed identifier handles combining mark pointer offset")
        let hoverStamp = LSPHoverStamp(epoch: 1, generation: 2, snapshot: pointerSource, fileURL: uri, symbol: symbol)
        check(hoverStamp.matches(epoch: 1, generation: 2, snapshot: pointerSource, fileURL: uri, symbol: symbol), "unchanged hover stamp accepted")
        check(!hoverStamp.matches(epoch: 2, generation: 2, snapshot: pointerSource, fileURL: uri, symbol: symbol), "pointer movement/cancel rejects old hover")
        check(!hoverStamp.matches(epoch: 1, generation: 3, snapshot: pointerSource, fileURL: uri, symbol: symbol), "edit/focus/off generation rejects hover")
        check(!hoverStamp.matches(epoch: 1, generation: 2, snapshot: pointerSource + "x", fileURL: uri, symbol: symbol), "unsaved changed snapshot rejects hover")
        check(!hoverStamp.matches(epoch: 1, generation: 2, snapshot: pointerSource, fileURL: uri.appendingPathExtension("other"), symbol: symbol), "Save As identity rejects hover")
        check(!hoverStamp.matches(epoch: 1, generation: 2, snapshot: pointerSource, fileURL: uri, symbol: nil), "leaving symbol rejects hover")
        let hovered = try await client.hover(uri: uri, language: .python, text: pointerSource, offset: 6)
        check(hovered["data"]["position"]["line"].int == 1 && hovered["data"]["position"]["character"].int == 2, "mock pointer offset transmitted as UTF16 position")
        check(hovered["contents"]["value"].string?.contains(pointerSource) == true && LSPHoverPresentation.text(hover: hovered)?.contains("probe(count)") == true, "mock hover receives unsaved content; display normalizes line endings")
        let signatures = try await client.signatures(uri: uri, language: .python, text: pointerSource, offset: 10)
        check(LSPHoverPresentation.text(hover: hovered, signatures: signatures)?.contains("Probe(count: int)") == true, "server constructor signature displayed without inference")
        let validFallback = try await client.hover(uri: uri, language: .python, text: "SIGNATURE_ERROR", offset: 0)
        let unavailableSignature = try await client.signatureSupplement(uri: uri, language: .python, text: "SIGNATURE_ERROR", offset: 0)
        check(unavailableSignature.value == .null && unavailableSignature.problem != nil && LSPHoverPresentation.text(hover: validFallback, signatures: unavailableSignature.value) != nil, "optional signature error preserves valid hover")
        let completionAfterError = try await client.complete(uri: uri, language: .python, text: "probe.l", caret: 7)
        check(!completionAfterError.isEmpty, "optional signature error leaves shared completion client working")
        let timeoutHover = try await client.hover(uri: uri, language: .python, text: "SIGNATURE_TIMEOUT", offset: 0)
        let timedOutSupplement = try await client.signatureSupplement(uri: uri, language: .python, text: "SIGNATURE_TIMEOUT", offset: 0)
        check(timedOutSupplement.value == .null && timedOutSupplement.problem != nil && LSPHoverPresentation.text(hover: timeoutHover) != nil, "optional signature timeout preserves hover")
        let afterTimeout = try await client.complete(uri: uri, language: .python, text: "probe.l", caret: 7)
        check(!afterTimeout.isEmpty, "completion remains usable after signature timeout")
        _ = try await client.complete(uri: uri, language: .python, text: "DIAG_ERROR", caret: 10)
        let batch = await client.diagnostics(for: uri)!
        let publishedVersion = await client.version(of: uri)
        check(batch.snapshot == "DIAG_ERROR" && batch.version == publishedVersion && LSPAssistance.diagnostics(batch).count == 1, "mock current versioned diagnostic accepted; stale/unversioned notifications rejected")
        _ = try await client.complete(uri: uri, language: .python, text: "DIAG_CLEAR", caret: 10)
        let clearedBatch = await client.diagnostics(for: uri)
        check(clearedBatch?.items.isEmpty == true, "mock current diagnostic clear survives later stale/unversioned errors")
        let definition = try await client.definition(uri: uri, language: .python, text: "probe", offset: 2)
        check(LSPAssistance.locations(definition).first?.uri == uri, "mock definition response parsed without opening documents")
        check(LSPAssistance.locations(.object(["uri": .string("command:run"), "range": .null])).isEmpty, "non-file definition URI rejected")
        let actions = try await client.codeActions(uri: uri, language: .python, text: "probe", range: NSRange(location: 0, length: 1))
        let actionVersion = await client.version(of: uri)
        let actionEdits = try LSPAssistance.actionEdits(actions[0], uri: uri, version: actionVersion, text: "probe")
        check(actionEdits.count == 1 && actionEdits[0].text == "Fixed", "mock actual single-document code action validated")
        var action = actions[0].object!
        action["command"] = .object(["command": .string("run.arbitrary"), "arguments": .array([])])
        do { _ = try LSPAssistance.actionEdits(.object(action), uri: uri, version: actionVersion, text: "probe"); fatalError("command accepted") } catch { print("PASS: arbitrary action command rejected") }
        let foreign = LSPJSON.object(["edit": .object(["changes": .object(["file:///tmp/other.py": .array([])])])])
        do { _ = try LSPAssistance.actionEdits(foreign, uri: uri, version: actionVersion, text: "probe"); fatalError("foreign edit") } catch { print("PASS: foreign/multi-document action refused atomically") }
        let malformed = LSPJSON.object(["edit": .object(["documentChanges": .array([.object(["textDocument": .object(["uri": .string(uri.absoluteString), "version": .string("bad")]), "edits": .array([])])])])])
        do { _ = try LSPAssistance.actionEdits(malformed, uri: uri, version: nil, text: "probe"); fatalError("bad version") } catch { print("PASS: malformed action version refused even with unknown version") }
        let hint = LSPJSON.object(["activeParameter": .number(1), "signatures": .array([.object(["label": .string("add(left: int, right: int)"), "parameters": .array([.object(["label": .array([.number(4), .number(13)])]), .object(["label": .array([.number(15), .number(25)])])])])])])
        check(LSPAssistance.signature(hint)?.active == NSRange(location: 15, length: 10), "server active parameter offset drives signature highlight")
        check(LSPAssistance.isInCall("add(1, ", caret: 7) && !LSPAssistance.isInCall("add(1,2)", caret: 8), "bounded call eligibility opens/closes hints")
        check(LSPAssistance.caret(after: actionEdits, original: 1, textLength: 5) == 5, "fix replacement caret shifts within new document bounds")
        let stamp = LSPDiagnosticStamp(uri: uri, revision: 2, version: 3)
        let staleABA = LSPDiagnosticBatch(uri: uri, version: 1, snapshot: "A", items: [])
        check(!stamp.matches(batch: staleABA, revision: 2) && !stamp.matches(batch: LSPDiagnosticBatch(uri: uri, version: 3, snapshot: "A", items: []), revision: 4), "A-to-B-to-A version/revision changes reject queued old diagnostics")
        let importItem = LSPJSON.object(["label": .string("Path"), "additionalTextEdits": .array([.object(["range": .object(["start": .object(["line": .number(0), "character": .number(0)]), "end": .object(["line": .number(0), "character": .number(0)])]), "newText": .string("from pathlib import Path\n\n")])])])
        let importOnly = try LSPAssistance.importEdits(importItem, uri: uri, version: 1, text: "Path", symbol: NSRange(location: 0, length: 4), caret: 4)
        check(importOnly.count == 1 && importOnly[0].range.length == 0, "pure import accepts server insertion sharing primary offset without rewriting identifier")
        var changingImport = importItem.object!; changingImport["insertText"] = .string("pathlib.Path")
        do { _ = try LSPAssistance.importEdits(.object(changingImport), uri: uri, version: 1, text: "Path", symbol: NSRange(location: 0, length: 4), caret: 4); fatalError("import renamed source") } catch { print("PASS: pure-import label cannot change the identifier") }
        do { _ = try LSPAssistance.actionEdits(actions[0], uri: uri, version: (actionVersion ?? 0) + 1, text: "probe"); fatalError("stale action") } catch { print("PASS: stale versioned action edit rejected") }
        let resourceAction = LSPJSON.object(["edit": .object(["documentChanges": .array([.object(["kind": .string("create"), "uri": .string(uri.absoluteString)])])])])
        do { _ = try LSPAssistance.actionEdits(resourceAction, uri: uri, version: 1, text: "probe"); fatalError("resource action") } catch { print("PASS: resource creation action rejected") }
        let unsafeHint = LSPJSON.object(["signatures": .array([.object(["label": .string("😀x(a)"), "parameters": .array([.object(["label": .array([.number(1), .number(2)])])])])])])
        check(LSPAssistance.signature(unsafeHint)?.active == nil, "signature highlight never splits a surrogate pair")
        let safeRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("semantic-definition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: safeRoot) }
        let safeFile = safeRoot.appendingPathComponent("target.py"); try "pass".write(to: safeFile, atomically: true, encoding: .utf8)
        check(LSPAssistance.safeDefinitionFile(safeFile, workspace: safeRoot) == safeFile, "safe in-workspace definition file allowed")
        let hiddenFile = safeRoot.appendingPathComponent(".secret.py"); try "private".write(to: hiddenFile, atomically: true, encoding: .utf8)
        let definitionLink = safeRoot.appendingPathComponent("link.py"); try FileManager.default.createSymbolicLink(at: definitionLink, withDestinationURL: safeFile)
        check(LSPAssistance.safeDefinitionFile(hiddenFile, workspace: safeRoot) == nil && LSPAssistance.safeDefinitionFile(definitionLink, workspace: safeRoot) == nil && LSPAssistance.safeDefinitionFile(safeFile, workspace: safeRoot.appendingPathComponent("other")) == nil, "hidden/symlink/outside-workspace navigation rejected")
        let delayedDefinition = Task { try await client.definition(uri: uri, language: .python, text: "DEFINITION_DELAY", offset: 0) }
        try await Task.sleep(for: .milliseconds(100)); delayedDefinition.cancel()
        do { _ = try await delayedDefinition.value; fatalError("definition canceled") } catch { print("PASS: canceled definition produces no navigation result") }
        _ = try await client.complete(uri: uri, language: .python, text: "fresh", caret: 5)
        let missingHover = try await client.hover(uri: uri, language: .python, text: "NO_HOVER", offset: 0)
        check(missingHover == .null && LSPHoverPresentation.text(hover: missingHover) == nil, "mock unavailable hover stays absent")
        let oldHover = Task { try await client.hover(uri: uri, language: .python, text: "HOVER_DELAY", offset: 0) }
        try await Task.sleep(for: .milliseconds(100)); oldHover.cancel()
        do { _ = try await oldHover.value; fatalError("hover cancel") } catch { print("PASS: canceled delayed mock hover request returns no result") }
        let freshHover = try await client.hover(uri: uri, language: .python, text: "fresh", offset: 0)
        check(LSPHoverPresentation.text(hover: freshHover)?.contains("fresh") == true, "fresh hover survives canceled stale response")
        let outstanding = Task { try await client.complete(uri:uri,language:.python,text:"DELAY",caret:5) }
        try await Task.sleep(for:.milliseconds(100))
        await client.stop()
        do { _ = try await outstanding.value; fatalError("off cancellation") } catch { print("PASS: off cancels pending mock request") }
        LSPProcesses.shared.stopAll()
        print("All core and mock integration checks passed. No real language servers tested.")
    }
}
