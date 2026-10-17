import Foundation
@main struct CopilotTests {
    static func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS: " + name) }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let client = LSPClient(processes: .copilot)
        try await client.start(.init(language: .python, executable: "/usr/bin/python3", arguments: [root.appendingPathComponent("SemanticTests/copilot_mock.py").path]), workspace: root, copilot: true)
        var statuses: [String] = [] // Status delivery is separately exercised through the handler.
        let status = StatusBox()
        await client.setMessageHandler { method, value in await status.record(method, value); return .null }
        let login = try await client.request("signIn", .object([:]))
        check(login["userCode"].string == "MOCK-CODE", "official device-flow shape remains opaque, synthetic code only")
        let command = CopilotInline.command(login["command"], name: "github.copilot.finishDeviceFlow")!
        _ = try await client.request("workspace/executeCommand", command)
        statuses = await status.values
        check(statuses.contains("Normal"), "authentication status notification delivered")
        do { _ = try await client.request("signIn", .object(["fail": .bool(true)])); fatalError("failure accepted") } catch { print("PASS: sign-in failure") }
        let auth = Task { try await client.request("signIn", .object(["delay": .bool(true)])) }
        try await Task.sleep(for: .milliseconds(50)); auth.cancel()
        do { _ = try await auth.value; fatalError("cancel accepted") } catch is CancellationError { print("PASS: authentication cancellation") }
        let burst = try await client.request("test/burst", .object([:]))
        check(burst["messages"].int == 1000, "1000-message small-chunk burst does not disconnect stdio")
        let uri = root.appendingPathComponent("Synthetic.py")
        let result = try await client.inlineCompletion(uri: uri, language: .python, text: "😀\r\nx", caret: 5)
        check(result["version"].int == 1 && result["position"]["line"].int == 1 && result["position"]["character"].int == 1, "inline request carries document version and UTF-16/CRLF position")
        let item = result["items"].array!.first!
        let edit = try CopilotInline.edit(item, text: "😀\r\nx", caret: 5)
        check(edit.range == NSRange(location: 5,length: 0), "validated plain-text insertion")
        try await client.notify("textDocument/didShowCompletion", .object(["item": item]))
        _ = try await client.request("workspace/executeCommand", CopilotInline.command(item["command"], name: "github.copilot.didAcceptCompletionItem")!)
        let delayed = Task { try await client.inlineCompletion(uri: uri, language: .python, text: "DELAY", caret: 5) }
        try await Task.sleep(for: .milliseconds(70))
        _ = try await client.inlineCompletion(uri: uri, language: .python, text: "new", caret: 3)
        do { _ = try await delayed.value; fatalError("stale returned") } catch is CancellationError { print("PASS: stale document version rejected") }
        let cancelled = Task { try await client.inlineCompletion(uri: uri, language: .python, text: "DELAY", caret: 5) }
        try await Task.sleep(for: .milliseconds(50)); cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled returned") } catch is CancellationError { print("PASS: stale inline request cancellation") }
        _ = try await client.inlineCompletion(uri: root.appendingPathComponent("Other.py"), language: .python, text: "other", caret: 5)
        let state = try await client.request("test/state", .object([:]))
        check(state["opened"].int == 2 && state["shown"].int == 1 && state["accepted"].int == 1 && state["cancelled"].int! >= 2, "retain requested documents, show/accept notifications, protocol cancellation")
        _ = try await client.inlineCompletion(uri: uri, language: .python, text: "DELAY plus", caret: 10)
        check(await client.version(of: uri) == 5, "returning document retains real synchronization version")
        for index in 0..<9 {
            _ = try await client.inlineCompletion(uri: root.appendingPathComponent("Bounded\(index).py"), language: .python, text: "bounded", caret: 7)
        }
        let bounded = try await client.request("test/state", .object([:]))
        check(bounded["opened"].int == 8, "provider history is bounded to eight already-requested documents")
        check(await client.version(of: uri) == nil, "least recently requested document is evicted")
        await client.closeCopilotDocuments()
        check((try await client.request("test/state", .object([:])))["opened"].int == 0, "permission narrowing closes all retained documents")
        check(CopilotInline.command(.object(["command": .string("arbitrary.command"), "arguments": .array([])]), name: "github.copilot.didAcceptCompletionItem") == nil, "arbitrary commands rejected")
        do { _ = try CopilotInline.edit(.object(["insertText": .object(["value": .string("snippet")])]),text:"x",caret:1); fatalError("snippet accepted") } catch { print("PASS: unsupported snippet rejected") }
        do { _ = try CopilotInline.edit(.object(["insertText":.string("x")]), text:"😀",caret:1); fatalError("surrogate boundary accepted") } catch { print("PASS: split UTF-16 surrogate boundary rejected") }
        let combining = try CopilotInline.edit(.object(["insertText":.string("a\u{301}bc"),"range":.object(["start":.object(["line":.number(0),"character":.number(0)]),"end":.object(["line":.number(0),"character":.number(1)])])]),text:"a",caret:1)
        check((combining.text as NSString).substring(from:combining.range.length) == "\u{301}bc", "combining suffix uses UTF-16 rather than grapheme drop count")
        LSPProcesses.shared.stopAll()
        let independent = try await client.request("test/state", .object([:]))
        check(independent["shown"].int == 1, "semantic reset does not stop Copilot process")
        LSPProcesses.copilot.stopAll()
        await client.stop()
        do { _ = try await client.inlineCompletion(uri: uri, language: .python,text:"off",caret:3); fatalError("off synchronized") } catch { print("PASS: stopped client refuses document synchronization") }
        let range = NSRange(location: 2,length: 2)
        let items = [LSPAssistance.Diagnostic(range: range,severity:2,message:"Warning detail",raw:.object(["source": .string("mock")])), LSPAssistance.Diagnostic(range:range,severity:1,message:"Error detail",raw:.object(["code":.number(7)]))]
        let target = LSPDiagnosticHover.target(items,at:2,length:5)!
        check(target.1.hasPrefix("Error (7)") && target.1.contains("Warning [mock]"), "overlapping diagnostics ordered with source/code")
        check(LSPDiagnosticHover.target(items,at:4,length:5) == nil, "half-open diagnostic boundary")
        let empty = [LSPAssistance.Diagnostic(range:NSRange(location:5,length:0),severity:1,message:"EOF",raw:.null)]
        check(LSPDiagnosticHover.target(empty,at:4,length:5)?.0 == NSRange(location:4,length:1), "zero-length EOF follows underline anchor")
        print("All offline Copilot and diagnostic checks passed. No real authentication or network used.")
    }
}
actor StatusBox { var values:[String] = []; func record(_ method:String,_ value:LSPJSON) { if method == "didChangeStatus" { values.append(value["kind"].string ?? "") } } }
