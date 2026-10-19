# Single-file Run (#8)

Run belongs to the document, independently of Semantic Completion, Copilot,
network consent and telemetry. Toolbar Run/Stop, the Run menu and Command-R /
Command-period invoke the same actions. Existing saved toolbar layouts receive
these two items once; other customization is preserved. The result pane uses a
horizontal native split inside the existing document content controller. Editor
split views share one `Document.runSession`; other documents own separate sessions.
Hiding results or moving focus does not stop a run.

## Native UI correspondence

- `DocumentWindowController` creates standard `NSToolbarItem` controls with system
  play/stop symbols, following its existing toolbar construction and customization.
- `ContentViewController` hosts a thin-divider `NSSplitView`; its existing editor
  controller and status-bar accessories stay intact.
- The pane follows the existing inspector's `NSHostingController` pattern, system
  typography, semantic colors, standard buttons, fields and disclosure groups.
  Output uses selectable, read-only `NSTextView` inside `NSScrollView`, as in the
  existing console. Labels are localized in `Run.xcstrings` (English/Japanese).
- Save uses the document's normal save delegate. Runtime selection/version
  confirmation uses native `NSOpenPanel` / `NSAlert` sheets. No installer is run.

These are implementation correspondences, **not visual/accessibility validation**.
Side-by-side screenshots and device interaction checks listed below remain required.

## Execution and result contract

The source must be saved `.py` or ordinary `.java`. Run waits for save completion;
cancelled/failed saves never launch. A changed buffer or disk version during
preparation requires another review/save. The result records a UUID, source URL,
monotonic document revision, buffer text, saved bytes and modification date.
The cwd is always that source's parent, displayed with the selected runtime.
No temporary copy of the source is run. Arguments are passed without a shell.

Python explicitly selected by the user takes priority, including a selected venv.
A broken explicit selection never falls back. Initial discovery checks only:

1. `<source-parent>/.venv/bin/python`
2. `/opt/homebrew/bin/python3`
3. `/usr/local/bin/python3`
4. `/usr/bin/python3`

The user sees candidates and confirms the selected executable/version before the
first run. Selection inspection uses the owned runner with a three-second timeout.
Python executes with `-u`, `PYTHONIOENCODING=utf-8`, `PYTHONUTF8=1`. `PYTHONHOME`,
`PYTHONPATH` and `PYTHONSTARTUP` are removed; the selected interpreter/venv is kept.
No ancestors, shell startup files or inherited PATH are searched.

Java defaults to `SemanticServers/jdk` in the app resources; an explicit JDK Home
overrides it. Both `bin/java` and `bin/javac` must be executable and resolve within
that same Home. External selection inspects both tools. Each run owns a UUID output
directory with empty sourcepath and isolated classes, using `-encoding UTF-8`,
`-proc:none`, `-implicit:none`, `-sourcepath`, `-classpath` and `-d`. It runs only after
compile exit 0, using `-Dfile.encoding=UTF-8 -cp <classes> <qualified-main>`. Java
tool-injection variables (`JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `JDK_JAVAC_OPTIONS`,
`_JAVA_OPTIONS`) and `CLASSPATH` are removed. Missing locale gets a UTF-8 fallback.
Only javac uses a controlled `en_US` diagnostic locale. The Java execution command
sets no `user.language` or `user.country`, preserving the user program's default
Locale and locale-dependent output. Launcher errors are classified separately
using recognized OpenJDK English/Japanese/German/Simplified-Chinese messages;
unrecognized diagnostics retain a generic explanation. Raw launcher stderr and
program output are never translated or rewritten by the app. Launcher recognition
scans anchored diagnostic lines beyond any preceding successful-compile warnings,
associating a missing-main message with its following signature advice. Java source must
already be saved as UTF-8; the existing encoding UI performs any user-approved
conversion. No user source, existing classes or existing directories are removed.

A lexical masker excludes comments, strings, chars and text blocks before finding
package and top-level classes. The filename's class is the default; a public class
with a mismatched filename reaches javac so its original mismatch diagnostic is
shown. Other non-public classes require an explicit qualified name in the pane.
There is no automatic trial of multiple main candidates. Modules, preview/compact
source, dependency resolution and multi-source builds are outside this feature.
Compiler errors, missing-main diagnostics, launch failures and exceptions remain
in raw stderr. Common Java diagnostic categories receive additional localized
explanations; unrecognized diagnostics retain a generic explanation.

`RunResult` is the reusable contract for #9: source, ID, phase, stdout/stderr bytes,
rendered text, omitted byte counts, decoding flags, termination and compile status.
`comparable` requires successful execution and complete, decodable streams.
No expected-output selection or comparison is implemented here.

## Pipes and process ownership

The C bridge uses `posix_spawn`, explicit argv/envp/cwd and a new process group.
Spawn and Stop serialize on its ownership lock. Descriptor creation, CLOEXEC
flagging, spawn and child-endpoint closure also share a process-wide runner lock.
Linux uses atomic `SOCK_CLOEXEC` / `pipe2(O_CLOEXEC)`; the Darwin fallback cannot
cross another runner's creation/spawn window, and Darwin spawn additionally uses
`POSIX_SPAWN_CLOEXEC_DEFAULT`. Darwin uses the supported standard `addchdir` API
rather than its deprecated `_np` spelling; strict warning checks remain enabled. The leader remains unreaped via
`waitid(WNOWAIT)` until group cleanup, preventing this runner from signalling a
reused PID/group ID. Stop closes input, sends group TERM, then KILL after 0.3 seconds.
Natural leader exit also cleans ordinary remaining descendants. Document close
stops the session. Application termination uses a registry independent of open documents, retaining
active sessions even after document close. It stops every retained session and
waits for its full background operation (including pipe drain and owned-directory
cleanup), not just group disappearance. Registry ownership is released only after
completion; shutdown also clears completed retained entries.
A daemon deliberately leaving the process group is outside this boundary; this is
not a sandbox or PTY.

Initial input is snapshotted as UTF-8 and sent unchanged. Default mode closes with
EOF after all bytes, including immediate EOF for empty input; it adds no newline.
Interactive mode keeps the pipe open. Later Send adds one LF; EOF closes after
queued sends and cannot be sent twice. Readiness means the initial bytes have been
sent and the pipe accepts input; it does **not** detect a program waiting on stdin.
Socket-backed stdin prevents SIGPIPE crashes without changing global signal policy.
Nonblocking writes, input-capacity polling, early-close handling and concurrent stdout/stderr draining
avoid backpressure deadlocks.

Each stream retains at most 10 MiB and continues draining beyond the cap. Omitted
byte counts are displayed. UTF-8 is reconstructed incrementally across chunks;
malformed bytes are replaced and flagged, while a truncated trailing scalar is
kept distinct from a decoding failure. UI refreshes are batched at 100 ms, reading
only new retained bytes. Streams are independent, never claimed as one ordered log.
Stderr alone does not imply failure.

At completion, up to 200 confirmed source diagnostics are listed; raw stderr is
retained independently. Python file/line, absolute javac file/line and Java stack
frames are matched only to this source and its package/top-level/inner classes.
Navigation checks URL, revision, text, modification date and bytes, selects and
scrolls the source, and offers Back. Changes (including edit/undo or Save As)
disable old navigation. Run diagnostics stay separate from LSP diagnostics.

## Cloud validation (Linux)

Commands:

```sh
python3 Scripts/test-run-process.py
SWIFTC=/tmp/ce-swift/usr/bin/swiftc RUN_TEST_JDK=/tmp/ce-jdk bash Scripts/test-run-core.sh
python3 Scripts/test-run-localization.py
```

- Process suite: 17 tests pass, including exact/empty/large stdin and EOF, interactive
  sends, repeated EOF, EPIPE, split UTF-8, invalid bytes, simultaneous stream floods
  with exact cap/omission counts, a paused fallback CLOEXEC/concurrent-spawn
  regression, exit/nonzero/signal/launch failure, spawn/Stop
  races, TERM ignoring, input backpressure, Unicode/space cwd and parent-first
  child/grandchild cleanup. A test-only injected monotonic clock verifies no KILL
  at 299 ms and escalation at 300 ms. Exited Linux zombies awaiting container init's reaper
  are distinguished from live processes. Darwin fixture observation uses a bounded
  batch `ps` state query instead of PID existence alone. After runner completion,
  the test allows at most one second for asynchronous SIGKILL delivery to leave
  no live fixture process; any still-live or unobservable PID fails closed.
  Zombies are already exited and need OS reaping, so they do not count as live.
  Initial/final states and elapsed settling time are recorded when needed.
  Regression tests keep a real owned zombie unreaped, reject a real still-live
  TERM-ignoring fixture within a short budget, and exercise bounded live→zombie
  settling / unknown-state failure with a fake clock. TERM-ignoring tests wait for a PID
  acknowledgement emitted after the handler is installed, rather than sleeping
  for presumed startup time. Descendants acknowledge readiness through a pipe
  before their parent exits. Exact SIGKILL and bounded Stop assertions are kept. Twenty repetitions each
  of the Stop/backpressure and parent-first descendant tests pass (40 checks).
- Swift core: passes runtime priority/no-fallback, PATH independence, argv/cwd/env,
  lexical masking, source/stale identity, incremental decoding, source-only error
  matching, fake-launcher compile/run/cancellation gating and result completeness. CR, CRLF
  and LF share exact navigation ranges. A closed-document owner is retained through
  Stop/KILL and background directory cleanup when shutdown runs immediately.
  Four real Python fixtures and ten real Java fixtures pass. Java tests also
  place an annotation processor/service registration, another source and existing
  classes in cwd; these are not used or removed. A failed second compile cannot
  run a previous successful class. `JDK_JAVAC_OPTIONS` attempts to inject a real
  sibling source are rejected. Compiler failure categories are exercised with an opposing Japanese compiler
  locale preceding the javac-only controlled locale. Missing-main and class-load
  launcher errors run under English, Japanese, German and Simplified Chinese.
  A real LocaleOutput fixture matches direct execution byte for byte as
  `ja-JP|10月`, proving the execution plan preserves the program's locale.
  A successful unchecked-warning compile followed by missing-main execution is
  classified in both English and Japanese. Its complete retained stderr is checked
  byte for byte against compiler warnings plus an independent launcher-only run.
- Localization: two tests pass for complete English/Japanese resources, standard
  Japanese terminology and independence from semantic/telemetry controllers.
- All modified Swift files parse with Swift 6.2.1; portable Swift/C type checking
  and strict C warnings pass. Temporary toolchains exist only under `/tmp`.
- Existing semantic core check cannot compile on Linux: unchanged `LSPModel.swift`
  imports `Darwin`. No existing test failure is represented as a pass.

## Required macOS / device verification (parent owns)

This Linux environment cannot type-check AppKit/SwiftUI against Apple's SDK, run
Xcode builds, inspect a packaged macOS app or verify VoiceOver. No Mac was used.
Before marking the draft ready, use an isolated QA bundle identity and preferences
domain. Do not install over the user's app or read/write its installed-app
preferences. Keep test data and artifacts within the designated QA directory.

Parent-reported Mac results on the older head `2a63e87` found a deprecated C API
warning under `-Werror`, a correct 2 MiB transfer taking 4.402 seconds (longer than
its former four-second test budget), and Japanese diagnostic classification test
failures. Those findings are addressed in this revision, but require a new-head
Mac rerun. The prior Mac transport disconnected during Xcode dependency resolution;
that full build's outcome is unknown and provides no AppKit/UI pass. Later Mac
Debug and Release-Sparkle builds on `4e621be` exited 65: Observation transformed
an unignored lazy session property, RunSession lacked an explicit FileEncoding
module import, and NSToolbar.Identifier is a String alias without rawValue. The
current revision marks the stable lazy reference @ObservationIgnored, imports the
defining module and uses the toolbar identifier directly. New-head Mac builds
remain required; Cloud syntax/macro type checks are not an AppKit build pass. The temporary Linux
Swift toolchain cannot link the standalone Observation runtime probe (undefined
`swift::threading::fatal` in libswiftObservation); macro type checking succeeds,
but this is not represented as a runtime or native-build pass.

Before marking the draft ready:

1. Build Debug and Release/Sparkle with the project's supported macOS/Xcode versions;
   verify the new C bridge, synchronized source/resource membership, save delegate,
   Swift concurrency checking and string catalog. Run existing project tests and
   the two portable run suites on macOS (especially Darwin spawn/chdir/waitid and
   socket SIGPIPE behavior). Re-run the concurrent CLOEXEC fallback test and confirm
   strict compilation without warning demotion. Verify large stdin completes within
   its ten-second I/O budget; Stop retains its separate two-second test deadline.
   Independent code review remains parent-coordinated.
2. In the distribution-shaped app, verify bundled `javac` and `java` are present,
   executable, from the same JDK and permitted by signing/hardened runtime. Verify
   selected external Python and `.venv` symlinks, Unicode paths and UTF-8 I/O;
   Finder launch with differing/no PATH must use the confirmed absolute runtime.
3. Exercise toolbar/menu/Command-R/Command-period on first-launch and existing
   customized toolbar layouts. Run once launches configured Python or Java through
   compile success only. Check absent/broken runtimes, explicit choice/version
   confirmation, save cancellation/failure, new Save As, non-UTF-8 Java guidance,
   main-class selection, all Java failure explanations and rerun after Stop.
4. Verify one session per document across editor splits and multiple windows;
   other documents do not share output. Switch documents in a directory window,
   hide/show the pane, move focus, close documents during save/compile/run and quit
   the app while fixtures have ordinary children/grandchildren or blocked input.
   Verify no owned live processes, descriptors or UUID compile directories remain.
5. Exercise initial input with no final LF, empty EOF, large input, interactive
   additional sends (+LF), repeated EOF, early child close and Stop under
   backpressure. Test malformed/split UTF-8, simultaneous stdout/stderr flood,
   omission counters, successful stderr-only output, nonzero and signal exits.
6. Click Python/javac/Java inner/helper-class locations, verify select/scroll/Back with LF, CRLF and CR-only sources,
   then edit, undo, Save As and externally update the source. Check stale warning
   and disabled navigation, including file deletion/replacement. Confirm LSP
   diagnostics remain independent and Run works with all language/Copilot support off.
7. Compare side-by-side screenshots with existing CotEditor toolbar, inspector and
   console at normal/narrow widths and in split view, Light/Dark and different
   accent colors. Check spacing, type, selection and focus, clipping/overflow,
   pane resize/hide/show and existing status-bar accessories. Test full keyboard
   traversal and VoiceOver labels/order for controls, input, streams and errors.
   Repeat everyday flows in Japanese and English; record screenshots and results.

The integration task owns the single coordinated v0.4.0 version/build bump. This
change intentionally does not alter release metadata, tags, releases or packaging.

### Parent-reported Mac checkpoint on cffa9dd

The isolated-identity Debug build succeeds. The portable core suite (four Python,
ten Java, locale/warning and ownership regressions) passes on that head. The
process suite passed 13/14: its immediate descendant PID-existence assertion failed,
then all three fixture PIDs were absent on subsequent inspection. The exact states
at that first observation are unavailable; this does not prove whether they were
zombies or briefly awaiting SIGKILL delivery. The revised test records actual states
and enforces the bounded no-live-process guarantee above. A real-live-process
negative regression prevents a persistent leak from being accepted as settling.
Cloud observations show the leader gone and descendants already zombies; the
separate zombie regression confirms PID existence still succeeds after exit.
The ps-based observer path is also exercised against real live/zombie fixtures
on Linux, without claiming a macOS run. Production process termination is unchanged.
Parent's Mac transport disconnected
mid Release build; its outcome and process state remain unknown. Re-run the new
head on Mac with isolated identity/preferences and retain its state observations.

### Toolbar invalidation correction

Mac QA on `99e7934` confirms Debug/Release-Sparkle builds, all 17 process tests,
packaged Java and native Run/stdin/EOF/keyboard Stop/navigation pass, while toolbar
Run can initially be disabled and completed runs can leave Stop enabled until a
pane interaction. The code had no bridge from observable `RunSession.active`
changes to AppKit toolbar validation, and the shared target validated toolbar
items against `NSApp.mainWindow` rather than their owning document window.

`active` transitions now synchronously call `validateVisibleItems()` for the
corresponding document's toolbars, following the existing native Touch Bar refresh
pattern. Toolbar creation and displayed-document changes also validate explicitly.
Toolbar actions/validation resolve their own window; menus retain main-window
routing. This covers initialization before a main window, asynchronous completion,
and independent document windows without polling, forced focus or extra UI input.

Two native `RunToolbarValidationTests` regressions check real NSToolbar item enabled
states immediately after asynchronous active/inactive changes without another UI
event, and ensure separate documents' toolbar states remain independent. They
require Mac execution; Cloud syntax/macro checks do not claim AppKit test passes.
Run these with an isolated QA identity/preferences domain, for example the same
parent-approved build overrides plus `-parallel-testing-enabled NO` and
`-only-testing:Tests/RunToolbarValidationTests` on the CotEditor scheme. Recheck the
initial saved-file toolbar and short-run completion without switching pane tabs.
The separately reported NES hosted-test issues are outside this change.
