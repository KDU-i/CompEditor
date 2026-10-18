// SPDX-License-Identifier: Apache-2.0
import Foundation
@main struct CopilotTextIdentityTests {
 static func main() async throws {
  func check(_ value: Bool, _ label: String) { precondition(value, label); print("PASS: " + label) }
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  let client = LSPClient(processes: LSPProcesses())
  try await client.start(.init(language: .python, executable: "/usr/bin/python3", arguments: [root.appendingPathComponent("SemanticTests/copilot_mock.py").path, "--nes-word-fixture"]), workspace: root, copilot: true)
  let uri = URL.temporaryDirectory.appendingPathComponent("SyntheticCanonicalSync.py")
  let nfd = "e\u{301} Hello!", nfc = "é Hello!"
  check(nfd == nfc && !LSPText.sameText(nfd, nfc), "canonical equality is not UTF16 snapshot identity")
  var expectedVersion = 0
  for source in [nfd, nfc, nfc + " tail", nfd + " tail", nfc + " tail!"] {
   expectedVersion += 1
   let response = try await client.nextEdit(uri: uri, languageId: "python", text: source, caret: 0)
   let state = try await client.request("test/sync", .object([:]))
   check(LSPText.sameText(state["text"].string, source) && state["version"].int == expectedVersion, "server reconstructs exact normalization/follow-up snapshot \(expectedVersion)")
   let item = response["edits"].array!.first!
   check(CopilotInline.nextEditTarget(item, uri: uri, version: expectedVersion) == .current, "current normalized edit version \(expectedVersion)")
   let edit = try CopilotInline.nextEdit(item, text: source)
   check(edit.range == (source as NSString).range(of: "Hello"), "server offset matches current UTF16 source \(expectedVersion)")
   check(LSPText.sameText((source as NSString).replacingCharacters(in: edit.range, with: edit.text), source.replacingOccurrences(of: "Hello", with: "Bye")), "normalization cannot misreplace neighboring text \(expectedVersion)")
  }
  // A canonical-only change must reset unobserved history to the exact baseline.
  let historyURI = URL.temporaryDirectory.appendingPathComponent("SyntheticCanonicalHistory.py")
  try await client.synchronizeDocument(uri: historyURI, languageId: "python", text: nfc)
  _ = try await client.prepareNextEditHistory(uri: historyURI, languageId: "python", previous: nfd, caret: 0)
  let baseline = try await client.request("test/sync", .object([:]))
  check(LSPText.sameText(baseline["text"].string, nfd) && baseline["version"].int == 1, "history baseline preserves exact observed UTF16")
  for (old, new) in [(nfd + " LATE_AI", nfc + " LATE_AI"), (nfc + " LATE_AI", nfd + " LATE_AI")] {
   let request = Task { try await client.nextEdit(uri: uri, languageId: "python", text: old, caret: 0) }
   for _ in 0..<100 {
    let state = try await client.request("test/sync", .object([:]))
    if LSPText.sameText(state["text"].string, old) { break }
    try await Task.sleep(for: .milliseconds(5))
   }
   try await client.synchronizeDocument(uri: uri, languageId: "python", text: new)
   do { _ = try await request.value; preconditionFailure("stale canonical response escaped") }
   catch is CancellationError { print("PASS: delayed NES response rejects canonical-only source change") }
  }
  let inline = Task { try await client.inlineCompletion(uri: uri, languageId: "python", text: nfd + " LATE_AI", caret: 0) }
  for _ in 0..<100 {
   let state = try await client.request("test/sync", .object([:]))
   if LSPText.sameText(state["text"].string, nfd + " LATE_AI") { break }
   try await Task.sleep(for: .milliseconds(5))
  }
  try await client.synchronizeDocument(uri: uri, languageId: "python", text: nfc + " LATE_AI")
  do { _ = try await inline.value; preconditionFailure("stale inline response escaped") }
  catch is CancellationError { print("PASS: delayed inline response rejects canonical-only source change") }
  await client.shutdownAndStop()
 }
}
