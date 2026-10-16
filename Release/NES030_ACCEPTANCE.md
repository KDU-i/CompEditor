# NES 0.3.0 implementation and release gate

Base: public main 5ed858595ec6e64a28dc917174d7986a67d93c7f (0.2.3 build 859).
Work is isolated in branch feat/nes-030; the user's dirty checkout is untouched.

## Required behavior

- Remember automatic inline and automatic next-edit preferences independently of code-sharing consent. Never persist a new consent implicitly.
- Synchronize only the eligible focused document after existing consent. Send real incremental edits, preserving UTF-16/CRLF boundaries; never invent edit history, read neighboring files or switch providers.
- Automatic inline and NES share one presentation owner. Valid inline text takes priority while typing; rejected/non-inserting inline items must not suppress eligible NES. Deliberate caret movement and post-accept opportunities may ask NES without racing the typing request.
- Accept only current-document, current-version next edits. Preserve cancellation on editing, IME, selection, focus, viewport and window changes; ignore stale responses.
- Show a real difference, allow navigation to its location, apply once as an undoable change, and restore exactly with Undo.
- Distinguish zero returned edits, unsupported method, timeout, service failure, stale/invalid result and presentation exclusion. Diagnostics retain only bounded in-memory fixed metadata; no source/candidate text, paths, account data, auth data or free-text server errors.

## Release gate

1. Unit and mock protocol coverage for incremental history, persisted flags, scheduling, stale/foreign versions, diff/accept/Undo, and cancellation. Existing completion/session suites pass.
2. Reproducible real-service Python and Java edit-history cases return genuine next edits and demonstrate display, navigation, acceptance and Undo. Synthetic fixtures are not evidence of service generation.
3. Full app build, separate-app UI verification and distribution/privacy/signature audits pass. Preserve existing Sparkle key and publication route; do not export secrets or replace /Applications.
4. Report exact diff, commit, service observations and limitations to parent; stop for independent review. No merge, auto-merge, tag or release before review passes.

## Initial evidence and hypothesis

The diagnostic build returned one normal inline item and zero next edits for a newly opened Python document. The official 1.552.0 npm distribution's NES provider has an ActiveDocumentHasNoEdits exit when recent-edit history is empty. CompEditor's current synchronization opens a document only when a request starts and describes each later change as a whole-document range replacement. Investigate observable-workspace startup and true incremental history before claiming a service limitation.

Official protocol: https://github.com/github/copilot-language-server-release/blob/main/README.md
Pinned implementation inspected: https://registry.npmjs.org/@github/copilot-language-server/-/copilot-language-server-1.552.0.tgz

## Completed validation on 2026-10-17 (local Mac)

- All seven offline scripts passed: Copilot core, parity, session preferences, incremental sync/history, NES policy/target validation, diagnostics, and diagnostics privacy boundary.
- Native AppKit acceptance suite passed 2 tests. Preview did not mutate the document; adoption had one Undo step and Redo restored it. IME marked text and a distinct auxiliary caret both refused adoption. The auxiliary-caret test exposed an earlier count guard that permitted one additional caret; request eligibility, preview validation and action application now compare actual positions, allowing only duplicates of the primary caret.
- The corrected real-service probe returned one valid current-target edit for each synthetic Python and Java rename. Exact identifier counts verify that a remaining old reference decreases and the new identifier increases (459 ms / 471 ms observed). Earlier substring matching incorrectly counted `total` inside `subtotal`; that test assertion was corrected.
- Separate QA app 0.3.0/build 860 built successfully after the caret guard change. Official server remains checksum-pinned 1.552.0. The original installed 0.2.3/build 859 app is untouched.
- Owner enabled context sharing in the QA connection panel. No consent, authentication or permission was granted by the agent. Existing official authentication was reused; only newly authored synthetic samples were sent.
- On the preceding QA build, a Python rename first returned an empty NES edits array (22 ms). A subsequent actual rename returned one edit (418 ms), displayed the real before/after diff (426 ms), and preserved the document during preview. Tab once moved to the target; Tab again adopted both remaining reference changes. One Undo restored precisely the pre-adoption text.
- With both automatic flags enabled, a further synthetic Python rename returned zero inline candidates, then one fallback NES candidate (497 ms) and displayed its real diff (505 ms). Automatic NES was returned to its prior off setting afterward. These observations do not imply a candidate is guaranteed for every request.
- CUA accessibility state omits the floating diff panel; screenshots showed the before/after proposal. Diagnostic metadata independently recorded response array/count and displayed state. No payload, path, token or arbitrary error text was added to diagnostics.

## Final optimized Release verification

The optimized 0.3.0/build 860 archive built successfully from reviewed tree `0ee1756b0a1193a3d5e6607cba2c34d9f3b8a4c6`. A separate wrapper reused the owner-enabled QA bundle ID. Only bundle identity/display labels and the QA telemetry endpoint changed; all 40 Mach-O section names and bytes matched the final production executable after ad-hoc resealing. The installed app remained 0.2.3/build 859.

- Python: genuine manual NES response count 1 (490 ms), displayed (505 ms). Before/after diff showed two remaining references changing to the new identifier. Tab once changed caret position 47 to 67 without editing; Tab again applied the change. One Undo restored the exact pre-adoption source; Redo restored the adopted source. A further real rename returned a second displayed proposal (459/470 ms); Esc removed it without changing the source.
- Java: a request after the first rename returned an actual empty edits array (5 ms). Following another real rename, manual NES returned count 1 (516 ms), displayed (525 ms), and proposed two remaining reference changes. Tab moved caret 94 to 115 without editing, then adopted the diff. Undo and Redo restored the corresponding exact states.
- Java, automatic inline OFF / automatic NES ON: a real rename generated an automatic NES request (51 ms debounce), response count 1 (542 ms), displayed (553 ms). Esc dismissed the panel without editing. This directly verifies independent NES automation in the optimized binary.
- Python and Java: Control-Shift-Down added a distinct auxiliary caret. Both manual inline and NES menu items were disabled. In the Java automatic-NES case, diagnostics recorded an attempt skipped with `multipleCarets` and no request-start/response entry for that ticket. Native tests separately verify that direct adoption refuses the same state.
- Original QA automation settings were restored (inline ON / NES OFF). No existing document was sent, replaced or discarded. Service ranking and empty responses remain outside the editor's control; one successful example does not guarantee a proposal for every edit.

## Distribution and updater verification

- App and source bounded privacy/artifact audits passed, including the packaged ZIPs. The app scanner traversed 68,987 files, 92 Mach-O binaries and 197 archives; these counts include nested archive contents.
- All 5,963 packaged semantic-runtime files matched the previously shipped runtime input. The unchanged corresponding-source supplement hash is `c3a26df9d55040908358105503a3b7db63c6a9fe719ff03da9d6174f65d3edb7`.
- Pinned official Copilot remains 1.552.0; Sparkle remains 2.10.0 with the existing fork public key/feed, mandatory signed feed/archive checks, no signature-failure fallback, automatic install/check flags OFF and profiling OFF. Version 0.3.0/build 860 exceeds installed 0.2.3/build 859.
- Final ad-hoc app/nested signatures passed strict verification. The official Sparkle tool signed the local archive and appcast using the existing dedicated Keychain account without exporting a private key, and verified both. The archive signature was independently verified with only the shipped public key. No Developer ID/notarization is claimed.
- Updater-policy, startup-update and artifact-audit regression tests passed. No actual install/relaunch, hosted 0.3.0 feed or Gatekeeper-first-launch test was performed; no endpoint was published and the installed app was not replaced.

## Remaining release gate

Independent parent review and publication verification are pending. Nothing has been committed, pushed, tagged, merged or released in this pass. No /Applications replacement is authorized by these QA approvals. Physical IME interaction and exhaustive wrapping geometry remain outside the completed native/unit coverage. Diagnostics are bounded metadata and the privacy scanner is heuristic, not proof of absence of every possible secret.

## Independent review follow-up: unsupported NES method

The initial review found that direct automatic NES could bypass the unsupported-method flag after JSON-RPC -32601, and that the setting menu could then prevent turning NES off. The controller now applies availability to automatic scheduling and every direct request entry, rechecks it after client preparation, and guards history preparation without the bypassing OR condition. An enabled automatic-NES setting remains switchable OFF when unsupported; re-enabling and the manual trigger remain disabled until recovery. Normal inline completion remains available.

Unsupported status is session-local. Ordinary input, caret movement and toggling automation do not reset it. A successful explicit “接続を確認” permits a fresh NES capability probe, as does starting a new language-server connection. A failed connection check preserves the unsupported status. No automatic sign-in, new consent or credentials are involved.

A native controller regression uses a local synthetic JSON-RPC peer that always returns -32601. It checks the actual NES RPC count after typing notifications, a deliberate caret move after the debounce interval and a programmatic manual action; checks the real menu validation/state and persisted OFF action; and confirms one new probe after a successful synthetic connection check, followed by suppression again. This mock is solely regression evidence, not evidence of real-service candidate generation.

Follow-up result: the serialized native AppKit suite passed all 3 tests. The unsupported-server controller test passed with NES RPC counts 1 after the initial -32601, 1 after repeated input/manual actions and a deliberate post-debounce caret move, and 2 after successful explicit connection verification allowed exactly one fresh probe. A subsequent input left the count at 2. The active NES option validated as enabled/ON while unsupported and was persisted OFF; re-enabling became available after the successful connection check. The test uses an unlocked foreground GUI session and an event-pumped test window. On this builder the test host was run with ENABLE_DEBUG_DYLIB=NO after loader-startup stalls; no production build flag or OS security setting changed. Offline Copilot, semantic core, updater and artifact regression scripts also passed (11 scripts).
