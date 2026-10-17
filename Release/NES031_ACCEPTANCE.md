# NES 0.3.1 acceptance record — independent re-review candidate

Baseline: public v0.3.0 commit 53327572ca71a6d0f10d1aa03aef59b2b757e759. Work is isolated on fix/nes-v031. The installed 0.3.0/build860 application and user documents are not replaced. QA uses a separate bundle identifier, synthetic documents and existing opaque authentication only.

## Review corrections

The first candidate failed independent review. Its signed artifacts are superseded. This revision corrects all three reported defects:

- Protocol synchronization, unobserved-history replay, response validation and semantic snapshot guards compare exact UTF-16 sequences. Canonically equivalent Swift Strings can have different protocol offsets. The new real-client/mock integration test checks NFD→NFC, NFC→NFD, subsequent edits, server-generated ranges, exact application and delayed NES/inline replies.
- Editor revision increments before AppKit synchronously sends its text-change notification. Rebase observers see the current revision. A real `insertText` case checks candidate validity without calling `typed()` manually; a fresh normalization document then dispatches Tab through the actual editor controller owner.
- Inline insertion is used only when its text and the original line suffix fit. Overflow uses a compact, character-wrapping surface with vertical scrolling, including width 360 and line wrapping enabled. Preview never silently truncates the candidate horizontally.

The supplied VS Code reference images (Library libfile_14e789f146a481918120709940f67f60 and libfile_a0fb11c737288191951f15359eb2965f) were actually inspected. Short insertions retain a restrained inline green background; old words are red with a small green replacement immediately below. Preview text uses the editor font, line height and baseline. Thin borders, 2-point vertical padding, small blue gutter arrows and exact-height layout space replace the former minimum 120×44 shadowed panel. Long/multiline edits use wrapping or stacked/side-by-side code surfaces without headings or diff-prefix decoration. Gutter drawing is clipped and its text matrix reset, preventing line numbers from escaping into code.

Ordinary completion generation remains possible beside NES, and explicitly opening the ordinary UI no longer discards NES in advance. The actual EditorTextView key/typing/mouse and ordinary-completion callbacks share one controller owner (the default remains the singleton). Both 449d54b CI runs later failed to observe the first native popup. The fixture had replaced its document with the raw string setter, bypassing the normal AppKit edit lifecycle. Popup preparation now uses insertText, verifies the revision increment and expected completion range, and lays out/scrolls the real caret before invoking completion. Debug-only opt-in test traces record invocation/candidate/insertCompletion boundaries without user text; they are absent from Release builds. Popup visibility and actual Tab/Esc assertions are unchanged, including the original bounded observation deadline. CI must confirm this corrected input path; local passes alone are not a CI acceptance. Tests therefore dispatch real AppKit keys through the injected QA owner rather than testing an unrelated controller. Native UI ownership covers the entire synchronous AppKit completion invocation, including an initially unselected popup that has not called insertCompletion. A push-CI failure exposed this previously missing phase; local lifecycle instrumentation confirmed the synchronous interval. The native popup test checks actual Esc cancellation and Tab adoption of exactly one ordinary candidate, without adopting the AI replacement. Explicit NES dismissal suppresses automatic regeneration on caret movement until a fresh edit or an explicit request.

## Evidence and limits

Exact commit/tree, final logs, CI status, screenshot Library IDs and signed artifact hashes belong in the external re-review packet. Evidence from older commits is historical and does not establish this revision's acceptance.

Offline checks include the existing ten suites plus `Scripts/test-copilot-text-identity.sh`. Native acceptance covers 16 Java/Python × LF/CRLF × insertion/replacement/deletion/multiline payloads; emoji, tabs and no trailing newline; preview text/Undo immutability; actual key dispatch; direct/far/line-start Tab; actual minimized edit-end caret; Undo/Redo and automatic-RPC suppression; non-key rebase; normalization; reversed replies; document switches; marked text/multiple carets; offscreen scroll/resize; native popup Tab/Esc; and dark/light visual captures at widths 800/360. A fresh normalization fixture uses a private UndoManager with explicit per-event groups, because XCTest executes several synthetic events in one task. Production Undo grouping remains unchanged; a discarded experiment that closed a document's automatic group is not part of this revision.

The earlier foreground blocker is resolved by using normal Document windows, an isolated QA app name/identity and current AppKit activation. Earlier blocked/failed runs are retained but not counted as passes. A previous CI run passed NES acceptance but failed an unrelated URLDetector timing assertion while other suites ran beside the modal popup. CI now executes the NES suite in an exclusive second invocation, preserving every test and the normal unit invocation.

Real-service probes must return valid current-document candidates in both synthetic Python and Java cases; zero candidates are not acceptance. These probes verify the protocol/provider path separately from UI acceptance. An explicit QA-only additive fixture (production files unchanged) verifies nonzero real-service Python/Java candidates through display, actual Tab adoption, edit-end caret and Undo/Redo; its reproducible patch and newest result are recorded externally. Physical keyboard IME and arbitrary RTL layouts remain unverified.

## Twenty-item disposition

PASS is scoped to the stated host behavior and evidence. Missing host features are residuals, not private-model differences. Do not claim every VS Code feature, setting or prediction is identical.

|No.|Outcome|Implementation / remaining difference|
|---|---|---|
|01|Provider difference|Inline-first/fallback and one active provider; standalone API does not expose VS Code joint-provider scheduling.|
|02|Provider difference|Existing cancellable 50ms debounce and duplicate suppression; provider latency/cache policy is not mirrored.|
|03|Provider difference; host corrected|Observed pre-edit/current-document history, exact UTF-16 replay and synchronization; no workspace-wide/cross-file history collection.|
|04|PASS|Empty single-caret moves/clicks retain compatible NES; selected text/marked text/multiple carets refuse.|
|05|PASS|Target anchor/navigation and exact current URI/version/text validation; foreign-document refusal. No cross-file adoption.|
|06|PASS, visual review required|Shape-specific compact green/red surfaces, deletion strike, responsive multiline layout and overflow fallback; actual reference images inspected.|
|07|PASS|Fitting inline green insertion moves the original suffix; overflow surface makes full text accessible; preview leaves source/Undo unchanged.|
|08|PASS, visual review required|Red old word and small green replacement immediately below, matched font/line height/baseline, minimal padding/border.|
|09|PASS|16 payload variants plus real-client normalization regression; single primary range only. Arbitrary multi-hunk/cross-file transactions remain unsupported host features.|
|10|PASS|Actual editor-key route plus near/direct, far/jump, line-start second Tab, consecutive-visible and indentation precedence tests.|
|11|PASS within host|Ordinary generation and actual native Tab/Esc ownership/adoption tested. Focusable hover and VS Code's Tab-focus setting are absent host features, not model differences.|
|12|PASS|Actual Esc dismissal; caret moves do not automatically regenerate until fresh input/explicit request. Ordinary popup Esc retains ownership.|
|13|PASS|Non-key notification rebase uses the new revision; before/after/matching/conflicting edits and normalization have regression coverage.|
|14|PASS|Caret ends at final minimized difference, including deletion/common suffix; no selected replacement.|
|15|PASS within fixture scope|Default-manager payload Undo/Redo and automatic RPC suppression; fresh private-event-manager normalization fixture distinguishes preceding edit from adoption. Production grouping is unchanged.|
|16|Provider/host residual|Post-accept request and continuing-visible Tab policy preserved. Provider prefetch/cache and NES word/line partial adoption are not implemented.|
|17|PASS within synthetic scope|Marked-text and auxiliary/multiple-caret refusal; physical IME conversion remains unverified.|
|18|PASS within tested layouts|Scroll/resize/offscreen retention, clipped gutter, responsive surfaces and long narrow wrapped insertion; arbitrary wrap/RTL remains unverified.|
|19|PASS|Independent persistence/policy and native unsupported-server toggle/reprobe; authentication unchanged.|
|20|PASS|Exact UTF-16 protocol sync/response guards, delayed canonical-change response rejection, reversed A/B replies, URI/version/epoch/cancellation and error distinctions.|

## Distribution and publication gate

Export committed source with `Scripts/prepare-release-source.py`, recording its exact tree. Build original Release arm64 identity with coverage disabled and anonymous path maps, using the existing cached/pinned runtime dependencies. Never distribute a QA bundle or an older signed candidate. Reaudit the app, matching source and corresponding sources; verify nested ad-hoc signatures and 0.3.1/build861, existing public key/feed and mandatory signature policy. Sign the archive/feed through official Sparkle tools and the existing dedicated Keychain account without key export or permission changes. Verify the archive using only the shipped public key and verify the feed with the official tool. Record fixed v0.3.1 links, bytes and hashes in the external packet.

Independent re-review and the parent's explicit instruction remain mandatory before merge/tag/release publication/latest-feed changes. Installation is excluded. No such action is authorized by a passing local test alone.
