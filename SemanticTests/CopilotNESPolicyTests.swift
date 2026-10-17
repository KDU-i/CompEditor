import Foundation
@main struct CopilotNESPolicyTests {
 static func main() throws {
  func check(_ value: Bool, _ label: String) { precondition(value, label); print("PASS: " + label) }
  let both = CopilotAutomaticPolicy(inline: true, nextEdits: true)
  check(both.request(after: .typing) == .inline, "typing keeps one inline owner")
  check(both.request(after: .caretMove) == .nextEdit && both.request(after: .postAccept) == .nextEdit, "caret and acceptance can request real next edits")
  check(!both.needsNextEditFallback(displayableInlineCount: 1, serverAvailable: true), "visible inline wins")
  check(both.needsNextEditFallback(displayableInlineCount: 0, serverAvailable: true), "filtered non-inserting inline does not suppress NES")
  check(!both.needsNextEditFallback(displayableInlineCount: 0, serverAvailable: false), "unsupported NES is not retried automatically")
  check(CopilotAutomaticPolicy(inline: false, nextEdits: true).request(after: .typing) == .nextEdit, "NES works with automatic inline off")
  check(CopilotAutomaticPolicy(inline: false, nextEdits: false).request(after: .typing) == nil, "both automatic options off sends no typing request")
  var selections = CopilotSelectionTriggerPolicy()
  let buffer = UUID(), otherBuffer = UUID()
  check(!selections.shouldRequest(buffer, line: 1, at: 0), "selection does not invent edit history")
  selections.edited(buffer, at: 0)
  check(!selections.shouldRequest(buffer, line: 1, at: 0.01), "recent trigger is also required")
  selections.requested(at: 0)
  check(selections.shouldRequest(buffer, line: 1, at: 0.01), "selection immediately after edit has no fixed debounce")
  check(!selections.shouldRequest(buffer, line: 1, at: 5), "same line retains five second cooldown")
  check(selections.shouldRequest(buffer, line: 1, at: 5.01), "same line resumes at cooldown boundary")
  check(!selections.shouldRequest(otherBuffer, line: 2, at: 6), "history remains scoped to edited document")
  check(!selections.shouldRequest(buffer, line: 2, at: 10), "ten second edit and trigger window expires")
  selections.edited(buffer, at: 11); selections.requested(at: 11)
  selections.rejected(at: 11)
  check(!selections.shouldRequest(buffer, line: 2, at: 11.1), "rejection suppresses selection and drops tracked document")
  check(!selections.shouldRequest(buffer, line: 2, at: 16), "elapsed rejection window alone does not revive dropped history")
  selections.edited(buffer, at: 16); selections.requested(at: 16)
  check(selections.shouldRequest(buffer, line: 2, at: 16), "new edit restores tracked selection triggers")
  var many = CopilotSelectionTriggerPolicy()
  let recent = (0..<40).map { _ in UUID() }
  for (index, document) in recent.enumerated() { many.edited(document, at: Double(index) / 100) }
  many.requested(at: 0.5)
  check(many.shouldRequest(recent[0], line: 1, at: 0.6), "forty recent documents do not evict the first trigger history")
  check(many.shouldRequest(recent[39], line: 1, at: 0.7), "latest recent document remains eligible too")
  let fresh = UUID(); many.edited(fresh, at: 11); many.requested(at: 11)
  check(!many.shouldRequest(recent[0], line: 2, at: 11), "expired history is pruned by the real ten-second trigger window")
  check(many.shouldRequest(fresh, line: 1, at: 11), "time-based cleanup preserves fresh history")
  let root = URL.temporaryDirectory.appendingPathComponent("nes-project-" + UUID().uuidString).resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  func write(_ path: String, _ text: String = "print('ordinary')\n") throws -> URL {
   let uri = root.appendingPathComponent(path)
   try FileManager.default.createDirectory(at: uri.deletingLastPathComponent(), withIntermediateDirectories: true)
   try text.write(to: uri, atomically: true, encoding: .utf8); return uri
  }
  func refused(_ uri: URL, _ label: String) {
   do { _ = try CopilotProjectTargetPolicy.snapshot(uri, root: root); preconditionFailure(label) }
   catch { print("PASS: " + label) }
  }
  let ordinary = try write("src/normal.py")
  try check(CopilotProjectTargetPolicy.snapshot(ordinary, root: root).text == "print('ordinary')\n", "explicit project exact source snapshot")
  refused(try write(".hidden.py"), "hidden source refused")
  refused(try write("passwords.py"), "secret filename refused")
  refused(try write("src/config.py", "api_key = \"abcdefghijk\""), "literal credential refused before navigation")
  refused(try write("node_modules/normal.py"), "dependency source refused")
  refused(try write("normal.txt"), "non-source refused")
  let outside = URL.temporaryDirectory.appendingPathComponent("outside-" + UUID().uuidString + ".py")
  try "outside".write(to: outside, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: outside) }
  refused(outside, "outside selected project refused")
  let link = root.appendingPathComponent("link.py")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
  refused(link, "symlink source refused")
  _ = try write(".gitignore", "private/\nignored.py\n*.java\n!Keep.java\n")
  refused(try write("private/normal.py"), "ignored parent refused")
  refused(try write("src/ignored.py"), "nested basename exclusion respected")
  refused(try write("Drop.java"), "wildcard exclusion respected")
  try check((CopilotProjectTargetPolicy.target(write("Keep.java"), root: root)).lastPathComponent == "Keep.java", "ordered exclusion negation respected")
  _ = try write("src/.copilotignore", "normal.py\n")
  refused(ordinary, "ancestor copilot exclusion respected")
  try FileManager.default.removeItem(at: root.appendingPathComponent("src/.copilotignore"))
  _ = try write(".git/config", "[core]\n excludesFile = /unapproved/global\n")
  refused(ordinary, "external exclusion configuration fails closed")
  try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
  _ = try write(".git", "gitdir: /unapproved/worktree-admin\n")
  refused(ordinary, "external worktree administration fails closed")
  let uri = URL(fileURLWithPath: "/synthetic/current.py")
  let current: LSPJSON = .object(["textDocument": .object(["uri": .string(uri.absoluteString), "version": .number(3)])])
  let stale: LSPJSON = .object(["textDocument": .object(["uri": .string(uri.absoluteString), "version": .number(2)])])
  let foreign: LSPJSON = .object(["textDocument": .object(["uri": .string("file:///synthetic/other.py"), "version": .number(3)])])
  check(CopilotInline.nextEditTarget(current, uri: uri, version: 3) == .current, "current target accepted")
  check(CopilotInline.nextEditTarget(stale, uri: uri, version: 3) == .staleVersion, "old target version refused")
  check(CopilotInline.nextEditTarget(foreign, uri: uri, version: 3) == .foreignDocument, "other document refused")
  check(CopilotInline.nextEditTarget(.null, uri: uri, version: 3) != .current, "missing target refused")
  let noop: LSPJSON = .object(["text": .string("x"), "range": try CopilotInline.rangeJSON(NSRange(location: 0, length: 1), in: "x")])
  do { _ = try CopilotInline.nextEdit(noop, text: "x"); preconditionFailure("no-op shown") } catch { print("PASS: no-op next edit refused") }
 }
}
