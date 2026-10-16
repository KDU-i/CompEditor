import Foundation
@main struct CopilotIncrementalTests {
 static func main() async throws {
  func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS: " + message) }
  func roundtrip(_ old: String, _ new: String) throws {
   let change = try LSPText.incrementalChange(from: old, to: new)
   let range = try LSPText.range(change["range"], in: old)
   check((old as NSString).replacingCharacters(in: range, with: change["text"].string!) == new, "incremental roundtrip")
  }
  for pair in [("abc", "axc"), ("", "x"), ("abc", ""), ("😀abc", "😃abc"), ("a\r\nb", "a\nb"), ("a\nb", "a\r\nb"), ("😀\r\nb", "😀\r\nc")] { try roundtrip(pair.0, pair.1) }
  let old = "def f(value):\r\n    return value\r\n"
  let new = "def f(number):\r\n    return value\r\n"
  let change = try LSPText.incrementalChange(from: old, to: new)
  check(change["text"].string == "number", "only changed identifier is sent")
  let client = LSPClient(processes: LSPProcesses())
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  try await client.start(.init(language: .python, executable: "/usr/bin/python3", arguments: [root.appendingPathComponent("SemanticTests/copilot_mock.py").path]), workspace: root, copilot: true)
  let uri = URL.temporaryDirectory.appendingPathComponent("SyntheticHistory.py")
  try await client.synchronizeDocument(uri: uri, languageId: "python", text: old)
  try await client.synchronizeDocument(uri: uri, languageId: "python", text: new)
  let state = try await client.request("test/sync", .object([:]))
  check(state["text"].string == new && state["version"].int == 2, "real client sends reconstructible incremental update")
  check(state["change"]["text"].string == "number", "recent history retains local rename instead of entire document")
  let baseline = try await client.prepareNextEditHistory(uri: uri, languageId: "python", previous: old, caret: 12)
  check(baseline != nil, "provider starts from actual pre-edit baseline")
  let again = try await client.prepareNextEditHistory(uri: uri, languageId: "python", previous: old, caret: 12)
  check(again == nil, "history initialization does not repeat per request")
  _ = try await client.nextEdit(uri: uri, languageId: "python", text: new, caret: 12)
  let replayed = try await client.request("test/sync", .object([:]))
  check(replayed["text"].string == new && replayed["change"]["text"].string == "number", "real rename replays after baseline initialization")
  await client.shutdownAndStop()
 }
}
