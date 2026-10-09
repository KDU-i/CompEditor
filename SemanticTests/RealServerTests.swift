// Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
// SPDX-License-Identifier: Apache-2.0
// Acceptance harness for separately approved, project-local real language servers.
import Foundation

@main struct RealServerTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let configURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let bundled = configURL.pathExtension == "app"
        let config: LSPConfiguration
        if bundled {
            let resources = configURL.appendingPathComponent("Contents/Resources")
            config = try LSPConfiguration(schemaVersion: 1, servers: [.python, .java].map { language in
                try LSPBundledServers.server(language, resources: resources, storage: root.appendingPathComponent(language.rawValue + "-storage"))
            })
        } else { config = try JSONDecoder().decode(LSPConfiguration.self, from: Data(contentsOf: configURL)) }
        try config.validate()
        for server in config.servers {
            let workspace = root.appendingPathComponent(server.language.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                let hoverText: String
                if server.language == .python {
                    hoverText = "# 😀\r\nclass HoverProbe:\n    def __init__(self, count: int, label: str = 'sample') -> None:\n        \"Build a local probe.\"\n        self.count = count\n    def render(self, repeat: int) -> str:\n        \"Return repeated text.\"\n        return 'x' * repeat\nprobe = HoverProbe(2, 'local')\nanswer = probe.render(3)\n\n"
                } else {
                    hoverText = "// 😀\r\npublic class Demo {\n/** Build a local probe. */\nDemo(int count, String label) {}\n/** Return repeated text. */\nString render(int repeat, String suffix) { return suffix.repeat(repeat); }\nvoid use() { Demo p = new Demo(2, \"local\"); String text = p.render(3, \"!\"); }\n}\n\n"
                }
                let hoverURI = workspace.appendingPathComponent("Hover-Documents/" + (server.language == .java ? "Demo.java" : "HoverProbe.py"))
                try FileManager.default.createDirectory(at: hoverURI.deletingLastPathComponent(), withIntermediateDirectories: true)
                if server.language == .java { try hoverText.write(to: hoverURI, atomically: true, encoding: .utf8) }
            let client = LSPClient()
            do {
                print("REAL \(server.language.rawValue): initialize")
                try await client.start(server, workspace: workspace)
                let initial: String
                let updated: String
                let marker: String
                let expected: String
                if server.language == .python {
                    initial = "value = 'example'\nvalue.low"
                    updated = "class Probe:\n    def unsaved_method(self):\n        return 42\nprobe = Probe()\nprobe.unsaved_"
                    marker = "value.low"; expected = "lower"
                } else {
                    initial = "public class Demo { void run() { String value = \"example\"; value.subs } }"
                    updated = "public class Demo { void unsavedMethod() {} void run() { this.unsavedM } }"
                    marker = "value.subs"; expected = "substring"
                }
                let uri = workspace.appendingPathComponent(bundled ? "Untitled-\(UUID().uuidString).\(server.language.fileExtension)" : (server.language == .python ? "Probe.py" : "Demo.java"))
                if !bundled { try initial.write(to: uri, atomically: true, encoding: .utf8) }
                let range = (initial as NSString).range(of: marker)
                let caret = NSMaxRange(range)
                let items = try await client.complete(uri: uri, language: server.language, text: initial, caret: caret)
                try JSONEncoder().encode(items).write(to: workspace.appendingPathComponent("CompletionCandidates.json"))
                print("REAL \(server.language.rawValue): \(items.count) initial candidates; labels: \(items.prefix(8).compactMap { $0["label"].string })")
                guard let item = items.first(where: { ($0["label"].string ?? "").hasPrefix(expected) }) else { throw LSPError.server("Missing semantic member \(expected)") }
                let resolved = try await client.resolve(item)
                let prefix = server.language == .python ? "low" : "subs"
                let edits = try LSPText.edits(resolved, text: initial, fallback: NSRange(location: caret - prefix.count, length: prefix.count), caret: caret)
                let replacement = NSMutableString(string: initial)
                for edit in edits.reversed() { replacement.replaceCharacters(in: edit.range, with: edit.text) }
                guard (replacement as String).contains(expected) else { throw LSPError.unsupportedEdit }
                print("PASS REAL \(server.language.rawValue): built-in semantic member and validated resolved replacement")
                let ranked = LSPPresentation.candidates(items, text: initial, fallback: NSRange(location: caret - prefix.count, length: prefix.count), caret: caret)
                guard ranked.first?.item["label"].string?.hasPrefix(expected) == true else { throw LSPError.server("Best actual member relevance mismatch") }
                print("PASS REAL \(server.language.rawValue): relevant typed-prefix candidate ranked first")
                let lineEndText = server.language == .python ? initial : "public class Demo { void run() {\nString value = \"example\";\nvalue.subs\n} }"
                let lineEndCaret = NSMaxRange((lineEndText as NSString).range(of: marker))
                let lineItems = try await client.complete(uri: uri, language: server.language, text: lineEndText, caret: lineEndCaret)
                let lineRanked = LSPPresentation.candidates(lineItems, text: lineEndText, fallback: NSRange(location: lineEndCaret - prefix.count, length: prefix.count), caret: lineEndCaret)
                guard let best = lineRanked.first, let suffix = best.ghost else { throw LSPError.server("Missing compatible actual-server ghost") }
                let resolvedGhostItem = try await client.resolve(best.item)
                let ghostEdits = try LSPText.edits(resolvedGhostItem, text: lineEndText, fallback: NSRange(location: lineEndCaret - prefix.count, length: prefix.count), caret: lineEndCaret)
                guard LSPPresentation.ghost(edits: ghostEdits, text: lineEndText, caret: lineEndCaret) == suffix else { throw LSPError.server("Resolved actual ghost differs") }
                print("PASS REAL \(server.language.rawValue): line-end ghost suffix \(suffix) agrees with resolved edit")
                let prefixSet = server.language == .python ? ["l", "lo", "low"] : ["s", "su", "sub"]
                let serverTriggers = await client.triggerCharacters
                for shortPrefix in prefixSet {
                    let text = lineEndText.replacingOccurrences(of: marker, with: "value." + shortPrefix)
                    let caret = NSMaxRange((text as NSString).range(of: "value." + shortPrefix))
                    guard let context = LSPAutomaticContext.trigger(text: text, caret: caret, characters: serverTriggers), context.character == nil else { throw LSPError.server("Short member prefix not eligible") }
                    let candidates = try await client.complete(uri: uri, language: server.language, text: text, caret: caret, trigger: context.character)
                    let presented = LSPPresentation.candidates(candidates, text: text, fallback: NSRange(location: caret - shortPrefix.count, length: shortPrefix.count), caret: caret)
                    guard presented.contains(where: { ($0.item["label"].string ?? "").hasPrefix(expected) }), presented.contains(where: { $0.ghost != nil }) else { throw LSPError.server("Missing short-prefix box/ghost candidates") }
                    print("PASS REAL \(server.language.rawValue): \(shortPrefix.count)-character member prefix eligible; box and ghost candidates available")
                }
                for rootPrefix in ["v", "va", "val"] {
                    let text = lineEndText.replacingOccurrences(of: marker, with: rootPrefix)
                    let caret = NSMaxRange((text as NSString).range(of: "\n" + rootPrefix))
                    guard LSPAutomaticContext.trigger(text: text, caret: caret, characters: serverTriggers) != nil else { throw LSPError.server("Short root identifier not eligible") }
                    let candidates = try await client.complete(uri: uri, language: server.language, text: text, caret: caret)
                    let presented = LSPPresentation.candidates(candidates, text: text, fallback: NSRange(location: caret - rootPrefix.count, length: rootPrefix.count), caret: caret)
                    print("REAL \(server.language.rawValue): root \(rootPrefix) candidates \(presented.prefix(5).compactMap { $0.item["label"].string })")
                    guard presented.contains(where: { ($0.item["filterText"].string == "value" || $0.item["label"].string == "value" || $0.item["label"].string?.hasPrefix("value :") == true) && $0.ghost != nil }) else { throw LSPError.server("Missing short root-identifier semantic variable/ghost") }
                    print("PASS REAL \(server.language.rawValue): \(rootPrefix.count)-character root identifier eligible; semantic variable and ghost available")
                }
                let advertised = await client.triggerCharacters
                guard advertised.contains(".") else { throw LSPError.server("Server does not advertise member trigger") }
                let dotText = initial.replacingOccurrences(of: marker, with: "value.")
                let dotCaret = NSMaxRange((dotText as NSString).range(of: "value."))
                guard let dotContext = LSPAutomaticContext.trigger(text: dotText, caret: dotCaret, characters: advertised), dotContext.character == "." else { throw LSPError.server("Dot incorrectly waits for identifier") }
                let triggered = try await client.complete(uri: uri, language: server.language, text: dotText, caret: dotCaret, trigger: dotContext.character)
                print("REAL \(server.language.rawValue): dot trigger \(triggered.count) candidates; labels: \(triggered.prefix(8).compactMap { $0["label"].string })")
                let triggerExpected = server.language == .python ? "lower" : "charAt"
                guard triggered.contains(where: { ($0["label"].string ?? "").hasPrefix(triggerExpected) }) else { throw LSPError.server("Missing triggered semantic member") }
                print("PASS REAL \(server.language.rawValue): advertised dot trigger and automatic context return semantic members")
                let updatedMarker = server.language == .python ? "probe.unsaved_" : "this.unsavedM"
                let updatedCaret = NSMaxRange((updated as NSString).range(of: updatedMarker))
                let changed = try await client.complete(uri: uri, language: server.language, text: updated, caret: updatedCaret)
                let unsavedExpected = server.language == .python ? "unsaved_method" : "unsavedMethod"
                guard changed.contains(where: { ($0["label"].string ?? "").hasPrefix(unsavedExpected) }) else { throw LSPError.server("Missing unsaved semantic member \(unsavedExpected)") }
                if bundled {
                    guard !FileManager.default.fileExists(atPath: uri.path) else { throw LSPError.server("Virtual unsaved URI unexpectedly written to disk") }
                } else {
                    let disk = try String(contentsOf: uri, encoding: .utf8)
                    guard disk == initial else { throw LSPError.server("Test unexpectedly changed the saved file") }
                }
                print("PASS REAL \(server.language.rawValue): didChange analyzes new unsaved method while disk remains unchanged")
                print("REAL \(server.language.rawValue): hoverSupported=\(await client.supportsHover) signaturesSupported=\(await client.supportsSignatures)")
                if bundled && server.language == .java {
                    let virtualSymbol = (hoverText as NSString).range(of: "render(3").location
                    let virtualHover = try await client.hover(uri: uri, language: .java, text: hoverText, offset: virtualSymbol)
                    let virtualDisplay = LSPHoverPresentation.text(hover: virtualHover)
                    print("REAL java: disk-absent virtual hover after lifecycle barrier = \(virtualDisplay ?? "<none>")")
                    guard !FileManager.default.fileExists(atPath: uri.path) else { throw LSPError.server("Virtual hover wrote document") }
                }
                func information(_ pattern: String, in source: String) async throws -> String? {
                    let range = (source as NSString).range(of: pattern)
                    guard range.location != NSNotFound, let symbol = LSPHoverPresentation.symbol(in: source, at: range.location + 1) else { throw LSPError.server("Missing hover test symbol") }
                    let value = try await client.hover(uri: hoverURI, language: server.language, text: source, offset: symbol.location)
                    var signatures: LSPJSON = .null
                    if let call = LSPHoverPresentation.callOffset(in: source, symbol: symbol) { signatures = try await client.signatures(uri: hoverURI, language: server.language, text: source, offset: call) }
                    let display = LSPHoverPresentation.text(hover: value, signatures: signatures)
                    print("REAL \(server.language.rawValue): hover pattern \(pattern) raw=\(value) signatures=\(signatures) display=\(display ?? "<none>")")
                    return display
                }
                let functionInfo = try await information("render(3", in: hoverText)
                guard let functionInfo, functionInfo.contains("repeat"), functionInfo.contains("render") || functionInfo.contains("str") else { throw LSPError.server("Missing actual hover method parameter/type") }
                let classCall = server.language == .python ? "HoverProbe(2" : "Demo(2"
                let constructorInfo = try await information(classCall, in: hoverText)
                guard let constructorInfo, constructorInfo.contains("count"), constructorInfo.contains("label") else { throw LSPError.server("Missing actual class-call constructor signatures") }
                let className = server.language == .python ? "HoverProbe" : "Demo"
                let classDeclaration = (hoverText as NSString).range(of: "class " + className).location + 6
                let classHover = try await client.hover(uri: hoverURI, language: server.language, text: hoverText, offset: classDeclaration)
                let classInfo = LSPHoverPresentation.text(hover: classHover)
                print("REAL \(server.language.rawValue): class declaration hover \(classInfo?.prefix(160) ?? "<none>")")
                print("REAL \(server.language.rawValue): function hover \(functionInfo.prefix(180))")
                print("PASS REAL \(server.language.rawValue): method parameters/types/docs and actual constructor signatures")
                let metadata: LSPJSON = .object(["function": .string(functionInfo), "constructor": .string(constructorInfo), "class": classInfo.map(LSPJSON.string) ?? .null])
                try JSONEncoder().encode(metadata).write(to: workspace.appendingPathComponent("HoverMetadata.json"))
                let changedHoverText = hoverText.replacingOccurrences(of: "repeat: int", with: "copies: int").replacingOccurrences(of: "int repeat", with: "int copies").replacingOccurrences(of: " * repeat", with: " * copies").replacingOccurrences(of: "repeat);", with: "copies);")
                let changedInfo = try await information("render(3", in: changedHoverText)
                guard changedInfo?.contains("copies") == true else { throw LSPError.server("Hover did not synchronize unsaved parameter rename") }
                let absent = try await client.hover(uri: hoverURI, language: server.language, text: changedHoverText, offset: (changedHoverText as NSString).length - 1)
                guard LSPHoverPresentation.text(hover: absent) == nil else { throw LSPError.server("Unexpected hover on empty line") }
                if server.language == .java { guard try String(contentsOf: hoverURI, encoding: .utf8) == hoverText else { throw LSPError.server("Hover modified saved file") } }
                else { guard !FileManager.default.fileExists(atPath: hoverURI.path) else { throw LSPError.server("Hover wrote virtual buffer to disk") } }
                print("PASS REAL \(server.language.rawValue): hover updates unsaved parameters, absent info stays absent, disk unchanged")
                await client.close(hoverURI)
                await client.close(uri)
                await client.stop()
            } catch {
                await client.stop(); LSPProcesses.shared.stopAll()
                throw error
            }
        }
        LSPProcesses.shared.stopAll()
        print("Real Java/Python semantic transport acceptance passed.")
    }
}
