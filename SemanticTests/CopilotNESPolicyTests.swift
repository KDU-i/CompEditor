import Foundation
import Darwin
@main struct CopilotNESPolicyTests {
 static func main() throws {
  setbuf(stdout, nil)
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
  try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
  func git(_ arguments: [String], at directory: URL = root) throws -> Int32 {
   let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
   process.arguments = ["--no-optional-locks"] + arguments; process.currentDirectoryURL = directory
   process.environment = ["PATH":"/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_TERMINAL_PROMPT":"0", "LC_ALL":"C"]
   process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
   try process.run(); process.waitUntilExit(); return process.terminationStatus
  }
  try check(git(["init", "-q"]) == 0, "synthetic Git repository initialized")
  try check(git(["config", "core.ignorecase", "true"]) == 0, "native case-insensitive Git setting")
  for (pattern, name) in [("sensitive.py\n", "Sensitive.py"), ("PRIVATE/\n", "private/normal.py"), (" foo.py\n", " foo.py"), ("*.py\n!Keep.py\n", "Drop.py"), ("[[:alpha:]]ile.py\n", "file.py"), ("space\\ .py\n", "space .py")] {
   _ = try write(".gitignore", pattern); let file = try write(name)
   try check(git(["check-ignore", "--no-index", "--quiet", "--", name]) == 0, "native Git excludes " + name)
   refused(file, "Git differential exclusion: " + name)
  }
  _ = try write(".gitignore", "*.py\n!Keep.py\n")
  try check(CopilotProjectTargetPolicy.snapshot(write("Keep.py"), root: root).text.hasPrefix("print"), "Git native negation permits explicit ordinary file")
  _ = try write(".gitignore", "private/\n!private/normal.py\n")
  refused(root.appendingPathComponent("private/normal.py"), "child negation cannot reopen ignored parent")
  _ = try write(".gitignore", "")
  _ = try write("include.conf", "[core]\n ignoreCase = true\n excludesFile = local-excludes\n")
  _ = try write("local-excludes", "Included.py\n")
  try check(git(["config", "include.path", "../include.conf"]) == 0, "root-local config include installed")
  refused(try write("included.py"), "root-local include/excludesFile respected")
  try check(CopilotProjectTargetPolicy.snapshot(ordinary, root: root).text.hasPrefix("print"), "root-local declarations no longer blanket-reject allowed source")
  _ = try write(".git/info/exclude", "Info.py\n")
  refused(try write("info.py"), "repository info exclusion respected")
  try check(git(["config", "--unset", "include.path"]) == 0, "root-only include removed before separate worktree fixture")
  // Worktree registration and common-directory exclusions are external metadata;
  // no code/objects/remote/helper are supplied to the policy's Git process.
  try check(git(["-c", "core.hooksPath=/dev/null", "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "--allow-empty", "-qm", "fixture"]) == 0, "empty synthetic commit")
  let worktree = root.appendingPathComponent("linked-project")
  try check(git(["worktree", "add", "-qb", "nes-test", worktree.path]) == 0, "real linked Git worktree created")
  let workSource = worktree.appendingPathComponent("normal.py")
  try "print('worktree')".write(to: workSource, atomically: true, encoding: .utf8)
  try check(CopilotProjectTargetPolicy.snapshot(workSource, root: worktree).text == "print('worktree')", "registered linked worktree source permitted")
  let workIgnored = worktree.appendingPathComponent("INFO.py")
  try "print('ignored')".write(to: workIgnored, atomically: true, encoding: .utf8)
  do { _ = try CopilotProjectTargetPolicy.snapshot(workIgnored, root: worktree); preconditionFailure("common exclude bypass") } catch { print("PASS: linked worktree honors common info/exclude") }
  try check(git(["config", "extensions.worktreeConfig", "true"]) == 0, "per-worktree configuration enabled")
  try check(git(["config", "--worktree", "core.excludesfile", "worktree-excludes"], at: worktree) == 0, "per-worktree exclusion configured")
  // excludesFile is relative to the user's working tree, not the config file.
  try "WorktreeOnly.py\n".write(to: worktree.appendingPathComponent("worktree-excludes"), atomically: true, encoding: .utf8)
  let workPrivate = worktree.appendingPathComponent("WorktreeOnly.py")
  try "print('ignored')".write(to: workPrivate, atomically: true, encoding: .utf8)
  do { _ = try CopilotProjectTargetPolicy.snapshot(workPrivate, root: worktree); preconditionFailure("worktree config bypass") } catch { print("PASS: linked worktree configuration exclusion respected") }
  try check(CopilotProjectTargetPolicy.snapshot(workSource, root: worktree).text == "print('worktree')", "per-worktree declarations preserve allowed source")
  let separate = root.appendingPathComponent("separate-project"), administration = root.appendingPathComponent("git-administration")
  try check(git(["init", "-q", "--separate-git-dir", administration.path, separate.path]) == 0, "separate Git directory fixture initialized")
  let separateSource = separate.appendingPathComponent("normal.py")
  try "print('separate')".write(to: separateSource, atomically: true, encoding: .utf8)
  try check(CopilotProjectTargetPolicy.snapshot(separateSource, root: separate).text == "print('separate')", "legitimate separate Git administration supported")
  let spoof = root.appendingPathComponent("unregistered-project")
  try FileManager.default.createDirectory(at: spoof, withIntermediateDirectories: true)
  try Data(contentsOf: worktree.appendingPathComponent(".git")).write(to: spoof.appendingPathComponent(".git"))
  try "print('unregistered')".write(to: spoof.appendingPathComponent("normal.py"), atomically: true, encoding: .utf8)
  do { _ = try CopilotProjectTargetPolicy.snapshot(spoof.appendingPathComponent("normal.py"), root: spoof); preconditionFailure("unregistered worktree pointer followed") } catch { print("PASS: worktree pointer requires reciprocal registration") }
  // A registered admin config can include another config within its trusted
  // common directory. An arbitrary outside include must still fail closed.
  _ = try write(".git/allowed-config", "[core]\n ignoreCase = true\n")
  try check(git(["config", "include.path", "allowed-config"]) == 0, "registered admin include installed")
  try check(CopilotProjectTargetPolicy.snapshot(ordinary, root: root).text.hasPrefix("print"), "registered admin includes supported")
  _ = try write(".git/conditional.conf", "[core]\n excludesFile = conditional-excludes\n")
  _ = try write("conditional-excludes", "Conditional.py\n")
  let canonicalBuffer = try { () throws -> UnsafeMutablePointer<CChar> in
   guard let result = realpath(root.path, nil) else { throw CocoaError(.fileReadUnknown) }; return result
  }()
  let canonicalRoot = String(cString: canonicalBuffer); free(canonicalBuffer)
  let conditionKey = "includeIf.gitdir:" + canonicalRoot + "/.path"
  try check(git(["config", conditionKey, "conditional.conf"]) == 0, "matching gitdir include configured")
  let conditional = try write("conditional.py")
  try check(git(["check-ignore", "--no-index", "--quiet", "--", "conditional.py"]) == 0, "native Git conditional exclusion")
  refused(conditional, "matching gitdir conditional config is honored")
  try check(CopilotProjectTargetPolicy.snapshot(ordinary, root: root).text.hasPrefix("print"), "conditional include preserves ordinary source")
  try check(git(["config", "--unset", conditionKey]) == 0, "matching conditional fixture removed")
  try check(git(["config", "includeIf.gitdir:/nonexistent/unrelated/.path", "/unapproved/unread.conf"]) == 0, "nonmatching include fixture configured")
  try check(CopilotProjectTargetPolicy.snapshot(ordinary, root: root).text.hasPrefix("print"), "nonmatching condition neither follows nor reads unrelated target")
  let nested = root.appendingPathComponent("workspace/subfolder")
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
  _ = try write("workspace/subfolder/Sensitive.py")
  _ = try write("workspace/subfolder/normal.py")
  _ = try write(".gitignore", "workspace/subfolder/sensitive.py\n")
  try check(git(["check-ignore", "--no-index", "--quiet", "--", "Sensitive.py"], at: nested) == 0, "native Git excludes through ancestor root")
  do { _ = try CopilotProjectTargetPolicy.snapshot(nested.appendingPathComponent("Sensitive.py"), root: nested); preconditionFailure("ancestor exclusion bypass") } catch { print("PASS: nested opened folder honors ancestor Git rules") }
  try check(CopilotProjectTargetPolicy.snapshot(nested.appendingPathComponent("normal.py"), root: nested).text.hasPrefix("print"), "nested opened folder permits unrelated ordinary source")
  _ = try write("include.conf", "[core]\n ignoreCase = true\n excludesFile = enclosing-excludes\n")
  _ = try write("enclosing-excludes", "workspace/subfolder/relative.py\n")
  _ = try write("workspace/subfolder/Relative.py")
  try check(git(["config", "include.path", "../include.conf"]) == 0, "enclosing repository config include installed")
  try check(CopilotProjectTargetPolicy.snapshot(nested.appendingPathComponent("normal.py"), root: nested).text.hasPrefix("print"), "nested folder supports checked enclosing-root config metadata")
  try check(git(["check-ignore", "--no-index", "--quiet", "--", "Relative.py"], at: nested) == 0, "native Git relative excludesFile is anchored to enclosing worktree")
  do { _ = try CopilotProjectTargetPolicy.snapshot(nested.appendingPathComponent("Relative.py"), root: nested); preconditionFailure("relative enclosing excludesFile bypass") } catch { print("PASS: nested scope honors enclosing relative excludesFile") }
  try check(git(["config", "include.path", "allowed-config"]) == 0, "admin include restored after enclosing-root fixture")
  _ = try write(".gitignore", "workspace/\n!workspace/subfolder/normal.py\n")
  do { _ = try CopilotProjectTargetPolicy.snapshot(nested.appendingPathComponent("normal.py"), root: nested); preconditionFailure("ancestor parent negation bypass") } catch { print("PASS: ignored enclosing folder cannot be unignored from within") }
  _ = try write(".gitignore", "")
  let safeConfiguration = try Data(contentsOf: root.appendingPathComponent(".git/config"))
  _ = try write(".git/objects/not-a-config", "[core]\nignoreCase=true\n")
  try check(git(["config", "include.path", "objects/not-a-config"]) == 0, "object pointer fixture configured")
  refused(ordinary, "Git object contents never treated as config metadata")
  try check(git(["config", "include.path", "../src/normal.py"]) == 0, "source pointer fixture configured")
  refused(ordinary, "source file never treated as include metadata")
  try safeConfiguration.write(to: root.appendingPathComponent(".git/config"), options: .atomic)
  check(true, "synthetic safe admin config restored")
  let unrelated = root.deletingLastPathComponent().appendingPathComponent("unrelated-" + UUID().uuidString + ".conf")
  try "[core]\nignoreCase=true\n".write(to: unrelated, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: unrelated) }
  try check(git(["config", "include.path", unrelated.path]) == 0, "unrelated pointer fixture configured")
  refused(ordinary, "unrelated outside config is not read/followed")
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
