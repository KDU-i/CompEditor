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
