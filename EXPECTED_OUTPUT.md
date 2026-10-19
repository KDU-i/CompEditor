# Expected output comparison (#9, v0.4.0)

This change stacks on #11 / `feature/8-single-file-run`, initially exactly
`2a63e87ac6c159533076c6425cd412aad5df3ef7`. Incorporates reviewed #8 update
`99e7934de10bc2aeccbcfe62b68e0ed900dd4a99` without duplicating its fixes.
Java execution keeps the program locale; javac diagnostic localization and
localized launcher classification (including warnings before launcher errors)
remain upstream responsibilities. Run's process ownership, save/runtime
flow, source snapshots, diagnostics, stdout/stderr contract and per-document
session remain owned by #8. No release/version, packaging, NES or cache changes.

## UI correspondence and behavior

The comparison lives inside the existing document Run pane. `NSOpenPanel` uses
no extension/UTType allowlist. Ordinary files (including `.out`, `.txt`, `.log`,
arbitrary extensions and no extension) are read explicitly; directories/packages
are rejected. There is no automatic discovery or execution of selected output.
The reader opens read-only, retains at most 10 MiB + one detection byte, validates
strict UTF-8 and removes only a leading UTF-8 BOM. Empty files are valid. Errors
replace the previous selection's verdict and describe invalid encoding, size,
file kind or access failure. Reload and Clear are explicit, document-local actions;
external changes do not mutate the loaded snapshot.

Standard buttons, a menu picker, system type/colors, read-only selectable
`NSTextView`/`NSScrollView`, and the existing hosting/split pane follow #8 and
CotEditor's console/inspector patterns. `ViewThatFits` arranges controls and the
two labeled excerpts vertically at narrow widths. English/Japanese strings use
the existing `Run.xcstrings`; user output is never translated. The existing Run
status/stale-source warning stays visible, with run UUID and a stderr-present
indicator. Comparison only uses stdout; exit/compile/signal/Stop status remains
separate. Semantic colors and text labels avoid color-only status cues.

Default comparison converts CRLF and CR to LF and otherwise compares UTF-8 bytes.
Strict mode preserves every byte. No trim, tokenization, case folding or Unicode
normalization occurs. UTF-8 validity is independently checked in the background
before a match. Finished exit-0 results with complete, decodable streams alone
qualify; valid stderr warnings are allowed but identified in the pane. Failed,
stopped, running, not-run, absent-expected and indeterminate states cannot display
Match. Switching modes reuses the same imported and run snapshots.

The first differing byte is reported as one-based logical line and UTF-8 byte
column (the UI explicitly labels the column units). CR, LF and CRLF are counted
as logical newlines even in strict mode. The first mismatching byte on each side is also shown in hex (or EOF), making
visually identical Unicode differences inspectable. Both total line counts, extra/missing
line count, final newline presence and premature EOF are textual. Whitespace
visibility marks space, tab, NBSP, CR and LF. Excerpts include a literal EOF marker;
full-output equality and detail rendering are separate. Only 160 preceding bytes
and 1024 following bytes per side are displayed, adjusted to UTF-8 boundaries.
Long single lines and late differences do not require an edit-distance matrix or
full-output text layout in the comparison view.

Reading/validation and O(n) byte comparison run on a shared background actor, serializing large work buffers across documents. Maximum
input sizes come from this reader and #8's stream bounds. The coordinator uses
separate load/comparison generations plus run ID, load ID and mode checks before
publishing results. Old imports, clear, reruns and mode changes invalidate pending
verdicts immediately. No input/output is sent externally or stored persistently.

## Cloud validation

Run from the repository root with a Swift 6.2 toolchain and optional full JDK:

```sh
SWIFTC=/tmp/ce-swift/usr/bin/swiftc RUN_TEST_JDK=/tmp/ce-jdk bash Scripts/test-expected-output.sh
SWIFTC=/tmp/ce-swift/usr/bin/swiftc RUN_TEST_JDK=/tmp/ce-jdk bash Scripts/test-run-core.sh
python3 Scripts/test-run-process.py
python3 Scripts/test-run-localization.py
```

The new suite covers extension-independent imports and invalid UTF-8 rejection,
empty/BOM/bounds/access failures, both modes, whitespace/blank lines/NBSP,
Japanese/emoji/NFC-NFD, EOF/extra final lines, CR-only coordinates, same-length
mismatches and first/last differences at 10 MiB. State checks cover running,
nonzero, signal, launch, cancellation, stderr warnings, truncation and decoding
flags. An async harness runs the production Observation coordinator with delayed
read/comparison dependencies to force A→B reads, old→new runs, clear, mode changes,
invalid import and explicit reload races. Real Python and Java compile/run
fixtures test both verdicts, strict newline differences, stderr warnings and
source/expected/cwd preservation using #8's runner.

Linux's downloaded Swift 6.2.1 dynamic Observation library has an unresolved
internal runtime symbol. The script links its shipped static stdlib on Linux;
macOS uses normal SDK/runtime linkage. The static Linux Foundation library emits
an upstream `mktemp` linker warning; the test does not call that routine directly.
Portable type checking and parsing cannot establish AppKit/SwiftUI SDK correctness.

Validated in Cloud Linux: 84 pure checks, 12 async coordinator checks (forced races and production background snapshots), four real
comparison fixtures (Python/Java match and mismatch), the inherited RunCore suite
with four Python/ten Java fixtures, 17 process tests and two localization tests
passed. New UI Swift syntax parsing and `git diff --check` passed. No Xcode build
or native UI/device pass is claimed.

## Required macOS gates (parent-owned)

No Mac was used. Before readiness/integration, build Debug and Release/Sparkle
with supported Xcode, run existing tests and these suites, and verify resource
membership and Swift concurrency/AppKit/SwiftUI type checking. Native-device QA
must use an isolated app identity/preferences, not the installed app.

In that isolated app, run correct/incorrect Python and Java fixtures; switch,
clear and reload arbitrary-extension/no-extension files while running; exercise
UTF-8/BOM/empty/10 MiB/oversize/unreadable/package selections; verify stopped,
nonzero/compile/signal/launch failures, truncated/invalid streams and stderr-only
warnings. Edit source after execution and confirm run identity/stale-source
behavior. Test EOF, final newline, CR-only, NFC/NFD, whitespace visibility, very
long lines and first/last large mismatches. Compare screenshots against existing
CotEditor console/inspector at normal/narrow widths, split view, Light/Dark and
system accent colors. Verify focus, selection, keyboard traversal, VoiceOver
labels/order and Japanese/English text. Record results/screenshots; these checks
are not claimed by Cloud tests. Follow #8's remaining device checklist as well.
