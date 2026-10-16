// Explicit opt-in only. Real service, existing opaque server-owned authentication.
// Only these self-contained synthetic documents are sent. No workspace files are read.
import Foundation
@main struct CopilotLiveNESTests {
 static func main() async {
  guard ProcessInfo.processInfo.environment["COMPEDITOR_RUN_LIVE_NES"] == "1", CommandLine.arguments.count == 2 else {
   print("STOP: explicit live-test opt-in and official server path required"); return
  }
  let client = LSPClient(processes: LSPProcesses())
  func identifierCount(_ name: String, in source: String) -> Int {
   source.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.filter { $0 == name }.count
  }
  var passed = 0
  do {
   try await client.start(.init(language: .python, executable: CommandLine.arguments[1], arguments: ["--stdio"]), workspace: URL.temporaryDirectory, copilot: true)
   let state = try await client.request("checkStatus", .object([:]))
   guard CopilotAccountState(state) == .authenticated else { print("STOP: existing authentication unavailable; no login started"); await client.shutdownAndStop(); return }
   let pythonBefore = "def calculate_total(price, quantity):\n    subtotal = price * quantity\n    tax = subtotal * 0.1\n    return subtotal + tax\n"
   let pythonAfter = "def calculate_total(price, quantity):\n    total = price * quantity\n    tax = subtotal * 0.1\n    return subtotal + tax\n"
   let javaBefore = "class Calculator {\n    static double total(double price, int quantity) {\n        double subtotal = price * quantity;\n        double tax = subtotal * 0.1;\n        return subtotal + tax;\n    }\n}\n"
   let javaAfter = "class Calculator {\n    static double total(double price, int quantity) {\n        double amount = price * quantity;\n        double tax = subtotal * 0.1;\n        return subtotal + tax;\n    }\n}\n"
   for (index, values) in [("python", pythonBefore, pythonAfter, "total"), ("java", javaBefore, javaAfter, "amount")].enumerated() {
    let (language, before, after, replacement) = values
    let uri = URL.temporaryDirectory.appendingPathComponent("compeditor-synthetic-live-\(index).\(language)")
    let caret = (after as NSString).range(of: replacement + " =").location + replacement.utf16.count
    // Simulate a normal editing session before the first manual NES request.
    _ = try await client.inlineCompletion(uri: uri, languageId: language, text: before, caret: min(caret, before.utf16.count), triggerKind: 1)
    _ = try await client.inlineCompletion(uri: uri, languageId: language, text: after, caret: caret, triggerKind: 1)
    let started = ProcessInfo.processInfo.systemUptime
    let baseline = try await client.prepareNextEditHistory(uri: uri, languageId: language, previous: before, caret: caret)
    let result = try await client.nextEdit(uri: uri, languageId: language, text: after, caret: caret)
    let items = result["edits"].array ?? []
    let version = await client.version(of: uri) ?? -1
    var valid = false
    for item in items {
     guard CopilotInline.nextEditTarget(item, uri: uri, version: version) == .current,
           let edit = try? CopilotInline.nextEdit(item, text: after) else { continue }
     let applied = (after as NSString).replacingCharacters(in: edit.range, with: edit.text)
     valid = applied != after && identifierCount("subtotal", in: applied) < identifierCount("subtotal", in: after) && identifierCount(replacement, in: applied) > identifierCount(replacement, in: after)
     if valid { break }
    }
    print("case=\(index + 1) baselineArray=\(baseline?["edits"].array != nil) baselineCount=\(baseline?["edits"].array?.count ?? 0) editsArray=\(result["edits"].array != nil) editsCount=\(items.count) validCurrentEdit=\(valid) elapsedMS=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
    if valid { passed += 1 }
   }
  } catch LSPError.timeout { print("failure=timeout") }
    catch LSPError.methodNotFound { print("failure=methodNotFound") }
    catch { print("failure=other") }
  await client.shutdownAndStop()
  print("realServiceCasesPassed=\(passed)/2; UI display/accept/Undo requires separate verification")
 }
}
