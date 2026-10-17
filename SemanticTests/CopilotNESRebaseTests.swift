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
  func applying(_ edits: [LSPText.Edit], to text: String) -> String {
   edits.reversed().reduce(text) { applying($1, to: $0) }
  }
  let multiSource = "old + middle + old"
  let multi = LSPText.Edit(range: NSRange(location: 0, length: multiSource.utf16.count), text: "new + middle + new", primary: true)
  let hunks = CopilotNextEditPolicy.hunks(multi, in: multiSource)
  check(hunks.count == 2 && hunks.last?.primary == true && hunks.first?.primary == false, "one outer API edit derives two independent hunks")
  check(LSPText.sameText(applying(hunks, to: multiSource), multi.text), "derived hunks exactly reconstruct provider result")
  let island = "old + updated😀 + old"
  let rebasedHunks = CopilotNextEditPolicy.rebasedHunks(hunks, from: multiSource, to: island)!
  check(LSPText.sameText(applying(rebasedHunks, to: island), "new + updated😀 + new"), "editing unchanged island preserves both surrounding changes")
  let combinedHunks = CopilotNextEditPolicy.combined(rebasedHunks, in: island)!
  check(LSPText.sameText(applying(combinedHunks, to: island), "new + updated😀 + new"), "combined preview preserves user edit in unchanged island")
  let firstTyped = "new + middle + old"
  let remainingHunks = CopilotNextEditPolicy.rebasedHunks(hunks, from: multiSource, to: firstTyped)!
  check(remainingHunks.count == 1 && LSPText.sameText(applying(remainingHunks, to: firstTyped), multi.text), "fully typed first hunk leaves later hunk available")
  check(CopilotNextEditPolicy.rebasedHunks(hunks, from: multiSource, to: "bad + middle + old") == nil, "conflict in one hunk rejects the proposal")
  let surrounding = "start old end"
  let center = CopilotNextEditPolicy.hunks(.init(range: NSRange(location: 6, length: 3), text: "new", primary: true), in: surrounding)
  let userTransaction = "START old END"
  let preserved = CopilotNextEditPolicy.rebasedHunks(center, from: surrounding, to: userTransaction)!
  check(LSPText.sameText(applying(preserved, to: userTransaction), "START new END"), "two unrelated user changes do not create artificial overlap")
  check(CopilotNextEditPolicy.hunks(.init(range: NSRange(location: 0, length: 5), text: "Goodbye", primary: true), in: "Hello").count == 1, "small word replacement stays one readable hunk")
  var seed: UInt64 = 31
  let tokens = ["a", "b", " ", "+", "\r\n", "😀", "é", "e\u{301}"]
  func sample() -> String {
   (0..<12).map { _ in seed = seed &* 6364136223846793005 &+ 1; return tokens[Int((seed >> 32) % UInt64(tokens.count))] }.joined()
  }
  for _ in 0..<100 {
   let before = sample(), after = sample()
   let edit = LSPText.Edit(range: NSRange(location: 0, length: before.utf16.count), text: after, primary: true)
   check(LSPText.sameText(applying(CopilotNextEditPolicy.hunks(edit, in: before), to: before), after), "deterministic Unicode hunk roundtrip")
  }
  let large = String(repeating: "x", count: 3000)
  check(CopilotNextEditPolicy.hunks(.init(range: NSRange(location: 0, length: 3000), text: String(repeating: "y", count: 3000), primary: true), in: large).count == 1, "complete rewrite has one actual changed region")
  let longIsland = String(repeating: "same😀 ", count: 4000) + "needle😀" + String(repeating: "same😀 ", count: 4000)
  let longBefore = "old " + longIsland + "old", longAfter = "new " + longIsland + "new"
  let longEdit = LSPText.Edit(range: NSRange(location: 0, length: longBefore.utf16.count), text: longAfter, primary: true)
  let longHunks = CopilotNextEditPolicy.hunks(longEdit, in: longBefore)
  check(longHunks.count == 2, "large single-line edit over former 2048/product caps keeps independent changes")
  check(LSPText.sameText(applying(longHunks, to: longBefore), longAfter), "large hunk reconstruction preserves exact Unicode")
  let changedIsland = longBefore.replacingOccurrences(of: "needle😀", with: "edited🌱")
  let shiftedLong = CopilotNextEditPolicy.rebasedHunks(longHunks, from: longBefore, to: changedIsland)!
  check(LSPText.sameText(applying(shiftedLong, to: changedIsland), longAfter.replacingOccurrences(of: "needle😀", with: "edited🌱")), "large candidate preserves edited Unicode island")
  let multilineIsland = (0..<4000).map { "unchangedLine\($0)()\r\n" }.joined()
  let multilineBefore = "old\r\n" + multilineIsland + "old", multilineAfter = "new\r\n" + multilineIsland + "new"
  let multilineHunks = CopilotNextEditPolicy.hunks(.init(range: NSRange(location: 0, length: multilineBefore.utf16.count), text: multilineAfter, primary: true), in: multilineBefore)
  check(multilineHunks.count == 2 && LSPText.sameText(applying(multilineHunks, to: multilineBefore), multilineAfter), "large multiline CRLF edit keeps separated changes")
  let exhausted = CopilotNextEditPolicy.hunks(longEdit, in: longBefore, budget: .zero)
  check(LSPText.sameText(applying(exhausted, to: longBefore), longAfter), "actual computation-budget exhaustion still reconstructs safely")
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
