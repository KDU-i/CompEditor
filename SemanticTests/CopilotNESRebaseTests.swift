import Foundation
@main struct CopilotNESRebaseTests {
 static func main() throws {
  func check(_ value: Bool, _ label: String) { precondition(value, label); print("PASS: " + label) }
  let source = "def f():\n    return value\n"
  let range = (source as NSString).range(of: "value")
  let edit = LSPText.Edit(range: range, text: "number", primary: true)
  func applying(_ edit: LSPText.Edit, to text: String) -> String { (text as NSString).replacingCharacters(in: edit.range, with: edit.text) }
  for prefix in ["# header\n", "😀", " "] {
   let after = prefix + source
   let rebased = CopilotNextEditPolicy.rebase(edit, from: source, to: after)!
   check(applying(rebased, to: after) == prefix + applying(edit, to: source), "rebase before target: " + prefix.debugDescription)
  }
  let after = source + "# end"
  check(applying(CopilotNextEditPolicy.rebase(edit, from: source, to: after)!, to: after) == applying(edit, to: source) + "# end", "unrelated suffix retained")
  let typed = (source as NSString).replacingCharacters(in: NSRange(location: range.location, length: 0), with: "num")
  check(applying(CopilotNextEditPolicy.rebase(edit, from: source, to: typed)!, to: typed) == applying(edit, to: source), "matching insertion consumed")
  let conflict = (source as NSString).replacingCharacters(in: range, with: "other")
  check(CopilotNextEditPolicy.rebase(edit, from: source, to: conflict) == nil, "overlapping conflict rejected")
  check(CopilotNextEditPolicy.rebase(edit, from: source, to: applying(edit, to: source)) == nil, "fully typed proposal exhausted")
  let broad = LSPText.Edit(range: NSRange(location: 0, length: source.utf16.count), text: applying(edit, to: source), primary: true)
  let minimal = CopilotNextEditPolicy.minimized(broad, in: source)
  check(minimal.range == range && minimal.text == "number", "wide primary edit minimized for final caret")
  let unicode = CopilotNextEditPolicy.minimized(.init(range: NSRange(location: 0, length: 4), text: "😀ab", primary: true), in: "😀ac")
  check(unicode.range == NSRange(location: 3, length: 1) && unicode.text == "b", "Unicode boundaries preserved")
  for newline in ["\n", "\r\n", "\r"] {
   let lines = ["a", "b", "c", "d", "e", "f"].joined(separator: newline)
   let target = (lines as NSString).range(of: "d")
   check(CopilotNextEditPolicy.directAccept(snapshot: lines, caret: (lines as NSString).range(of: "c").location, range: target, continuing: false, visible: false), "line proximity with " + newline.debugDescription)
  }
  let combiningProposal = LSPText.Edit(range: NSRange(location: 0, length: 0), text: "e\u{301}clair", primary: true)
  let combiningRemainder = CopilotNextEditPolicy.rebase(combiningProposal, from: "", to: "e")!
  check(applying(combiningRemainder, to: "e").utf16.elementsEqual("e\u{301}clair".utf16), "partial grapheme preserves combining mark")
  let decomposed = "e\u{301} tail"
  let composed = "é tail"
  let accentEdit = LSPText.Edit(range: (decomposed as NSString).range(of: "tail"), text: "end", primary: true)
  let accentRebase = CopilotNextEditPolicy.rebase(accentEdit, from: decomposed, to: composed)!
  check(applying(accentRebase, to: composed).utf16.elementsEqual("é end".utf16), "canonical equivalent input still rebases UTF16 offset")
  let text = "a\nb\nc\nd\ne\nf\n"
  let target = NSRange(location: 6, length: 1)
  for caret in [4,5,6,7,8,9] { check(CopilotNextEditPolicy.directAccept(snapshot: text, caret: caret, range: target, continuing: false, visible: false), "direct near line at \(caret)") }
  check(!CopilotNextEditPolicy.directAccept(snapshot: text, caret: 0, range: target, continuing: false, visible: true), "remote candidate jumps")
  check(CopilotNextEditPolicy.directAccept(snapshot: text, caret: 0, range: target, continuing: true, visible: true), "visible consecutive edit accepts")
  check(!CopilotNextEditPolicy.directAccept(snapshot: text, caret: 0, range: target, continuing: true, visible: false), "offscreen consecutive edit jumps")
 }
}
