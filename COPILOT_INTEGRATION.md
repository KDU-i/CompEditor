# Copilot inline completion and diagnostic hover

This local change adds official GitHub Copilot inline completion for Java/Python and diagnostic-underlining hover. No commit, push, merge or publication was performed.

## Connecting in the delivered app

Open `../Deliverables/CompEditor-default-ready.app` or the updated `../Deliverables/CompEditor-live-fixed.app`. The normal macOS arm64 app bundles official Copilot Language Server 1.552.0 and automatically selects it using app-relative paths. Manual executable selection is no longer required. **GitHub Copilot → Choose Official Language Server…** remains available as an override.

1. **Inline Suggestions** starts ON on a fresh launch. This preference does not authorize transmission or start the server.
2. Choose **Sign In to GitHub…**, read the context-sharing explanation, then choose **Enable and Send Context** if appropriate.
3. A **GitHub Copilot — 接続状況** panel appears immediately. The panel and menu indicator distinguish connecting, authenticated, authentication required, failure, timeout and OFF.
4. Existing official-server authentication may be reused. Success explicitly displays **認証済み — 接続完了** and explains why a browser may not open.
5. If a device code is required, the user completes browser authorization themselves. CompEditor never reads, extracts, logs or writes access tokens, and does not reuse another extension's tokens.
6. Close the status panel and type Java/Python. Tab accepts a suggestion; Escape dismisses it.

Executable overrides are session-only. Startup checks existing official-server authentication without completing a new OAuth device flow. Transmission consent is separate: the optional remember-on-this-Mac checkbox is OFF by default. Only connection-enabled and remembered-consent booleans are stored by the editor. Without remembered consent, a fresh launch requests explicit consent before document synchronization. Explicit OFF survives restart and cancels work and document synchronization. Normal shutdown sends shutdown/exit without signOut. The official server owns its opaque authentication state; the editor does not inspect or extract credentials.

The native status panel remains visible through the terminal result; **Status…** reopens it. Initialize/sign-in requests use 15-second bounds, post-auth readiness waits up to 15 seconds, and a browser-device-flow command waits up to five minutes. Failure descriptions use fixed classifications and never print arbitrary auth/error payloads. Cancel Sign In drops the old client so a retry starts with the current connection generation.

## Packaging and provenance

`Scripts/package-copilot-server.py` copies only the checksum-pinned approved native release. It downloads or executes nothing. `Scripts/build-semantic-editor.sh` includes this packaging step. Builders can set `COPILOT_SERVER` to an explicitly approved staging input; no user-specific absolute path is embedded in runtime lookup.

App contents: `Contents/Resources/CopilotServer/copilot-language-server`, `Notices/`, and `manifest.json` with public source/version/SHA-256 metadata. The runtime detector verifies the pinned checksum and notice presence and refuses symlink/counterfeit executables. Packaging refuses symlink inputs/destinations and atomically replaces the binary to protect an already running process's old inode.

Official release: `@github/copilot-language-server-darwin-arm64` 1.552.0. Both native and same-version common npm archives were verified against their npm SHA-512 integrity values. Native executable SHA-256: `fd94d41828e75ff29586a3d3b1029ff203f69fb4d947120a24979e6ac75c5df0`. The complete official MIT LICENSE, zod LICENSE, and vscode-jsonrpc license/third-party notices are retained verbatim from the same-version common package. Service eligibility and terms are separate from the MIT software distribution license.

Official references reviewed on 2026-10-12:

- https://github.com/github/copilot-language-server-release — macOS native packaging, stdio LSP, signIn device flow, status notifications and inlineCompletion.
- https://github.com/github/copilot-language-server-release/blob/main/LICENSE — MIT distribution license and notice retention.
- https://docs.github.com/en/copilot/responsible-use/inline-suggestions — context and service behavior.

## Completion and diagnostic behavior

The integration uses stdio JSON-RPC with telemetry disabled, incremental synchronization, document versions and UTF-16 formatting/position validation. No project root/workspace folders are advertised. Only a focused, explicitly enabled Java/Python document is synchronized after consent and a ready authenticated connection. The official server may derive additional context from document URIs, as explained by the transmission consent.

Automatic edits schedule suggestions after a 50 ms client debounce; Option+Backslash requests manually, Option+[ / Option+] cycle alternatives, Command+Right accepts the next word and the menu accepts the next line. Text, selection, focus, document identity, scrolling, activation and OFF invalidate pending work. Insertion-only plans retain the existing suffix around the caret; original provider ranges are applied exactly once. Multiline ghosts use temporary layout gaps without changing text/Undo; candidates over 200 lines use a scrollable panel. The owner requested a single suggestion UI: a displayed, current AI preview dismisses ordinary lists, selections, timers and pending requests, and Tab accepts that AI preview. Loading, empty responses and failures leave ordinary completion available; an explicit ordinary-completion command dismisses AI. This deliberately differs from VS Code’s default ordinary-popup priority. Each partial/full acceptance has its own Undo stop and provider feedback. Experimental Next Edit Suggestions use the public copilotInlineEdit API and a separate Before/After diff with Tab jump/accept. Current indentation and one syntax-first languageId are used. Other languages require separate opt-in. Details and limits: [COPILOT_VSCODE_PARITY.md](COPILOT_VSCODE_PARITY.md).

Diagnostic hit testing prioritizes current diagnostics, including punctuation and zero-length underline anchors. Overlapping diagnostics show severity, source/code and message. Stale snapshots/file identities are ignored. Updating diagnostics, text, selection, focus, geometry or pointer targets cancels the hover. Symbol hover remains the fallback. The plain-text tooltip wraps long messages and limits itself to 12 lines; Show Diagnostics remains available for longer messages.

## Confirmed causes and validation

The earlier UI changed only an internal Connected string on existing-auth success, leaving no visible result. The new automatically shown connection panel fixes that. A second issue was confirmed in a bundled official-server reproduction: the eight-chunk stdio queue overflowed on a burst of small messages. The receiver now limits total pending bytes to 16 MiB (with an 8 MiB per-chunk limit) and preserves fixed failure classifications. It accepts normal bursts without an arbitrary chunk-count restriction.

- Final build and AppKit: 15 tests passed (`../default-server-verified-appkit.log`), including initial ON/no transmission, counterfeit/symlink detection, multiline preview, long diagnostic wrapping, UTF-16 diagnostic hit testing and Undo/composition behavior.
- Semantic core/protocol/mock: 114 checks passed (`../default-server-core.log`). Copilot mock: 19 checks passed (`../bundled-burst-mock-tests.log`), including a 1,000-message burst, auth success/failure/cancel, stale versions, protocol cancellation, command filtering and OFF synchronization refusal.
- Packaging checks refused counterfeit inputs and symlink destinations before copying. Bundled `--version` returned 1.552.0.
- The updated bundled official stdio client received real Java/Python candidates, rejected stale responses and refused synchronization after OFF (`../bundled-byte-budget-live.log`). Only newly created non-confidential fixtures were used. No OAuth or credential inspection was performed by the agent.
- **Normal app UI, not QA:** a fresh launch automatically selected the bundled server; no file-selection action occurred. Sign In retained transmission consent. After Enable and Send Context, the visible panel changed from **接続中…** to **認証済み — 接続完了** and explained existing-auth reuse. A real Python ghost appeared in `LiveCopilotSynthetic/DefaultConnection/DefaultConnection.py`; Tab inserted it and one Undo removed it. The verification session was turned OFF afterward. This historical 0.2.0 check predates the 0.2.1 separate startup-authentication/consent state. See Release/V0.2.1.md.
- Previous native UI checks confirmed full three-line Java preview, Tab insertion/one Undo and OFF→ON official reconnection. User physical-pointer operation confirmed a Pyright diagnostic popup over `HoverCheck.py`'s 2nd-line red-underlined string. The subsequent tooltip wrapping revision was verified in AppKit without a separate physical-pointer rerun.

A forced native-UI timeout and new browser-device authorization were not performed in the final normal-app run. The timeout/failure paths are bounded and explicit; offline protocol auth failure/cancel checks passed. Account quota/billing, official-server credential storage, and long-term network reliability remain uninspected.

## Source and user-document safety


Full original backup: `../Backups/CompEditor-privacy-da3f5804d`; this follow-up's preimages: `../Backups/BeforeBundledConnection`. Original files are updated only after complete preimage comparisons. Existing app processes, user documents and unsaved edits are not closed/overwritten. Executable updates to the older latest-app path use atomic replacements, so its running process retains its old code until the user restarts or opens the new app copy. All delivered executable hashes are recorded in `../final-delivered-code-sha256.json`.


Latest validation: `../parity-delivery-appkit.log` (17 passed), `../parity-delivery-core.log` (114 checks), `../parity-delivery-copilot.log` (19 checks), `../parity-delivery-protocol.log` (25 checks). Normal UI candidate/partial/suffix/NES/ordinary-list tests are recorded in `../parity-native-ui-verification.txt`. Official live new synthetic Java/Python fixtures each produced an eligible candidate; NES returned a supported empty response (`../parity-live-tests.log`). No real NES candidate, physical IME/multiple-caret stress, or exhaustive wrapping geometry is claimed.

### 0.2.2 接続画面

「接続状況…」で、認証状態、AI補完の有効状態、送信への同意、公式言語サーバーの準備状態を個別に確認できます。画面内で接続確認、サインイン／サインアウト、認証の取消、サーバー選択ができます。閉じる／Escは画面を閉じます。コードの送信同意は記憶するチェックを初期OFFとし、明示した場合だけ次回起動に引き継ぎます。

## 0.3.0 NES work in progress

NES requires actual recent edits, not only the current file snapshot. Copilot updates now use a minimal incremental UTF-16 range instead of replacing the entire document. The first NES opportunity initializes the official provider's lazy history observer from an actually observed pre-edit snapshot, then replays that real edit. At most one pre-edit snapshot (up to one million UTF-16 units) is retained in memory; it is never logged or persisted. No neighboring files or additional provider are used.

Automatic inline and NES preferences are independent persisted booleans, separate from context-sharing consent. Typing prioritizes a displayable inline candidate and may fall back to NES after parsing/filtering. With inline automation off, NES can request directly. Deliberate caret movement and post-accept opportunities can ask NES; text/selection/focus/viewport invalidation and revision checks remain in effect. Results for another document, stale versions and no-op edits are refused.

`Diagnostics…` shows the latest 200 fixed-metadata events in process memory. It accepts no document/candidate text, URI, account data, auth data or arbitrary server errors; no file or network sink is added. Open it after a request completes, since making another panel key retains the existing cancellation behavior.

Explicit live protocol tests use only bundled synthetic Python/Java rename examples and existing opaque official authentication. Both returned real, current-document next edits on this builder. Real Python service UI display/navigation/acceptance/one-step Undo and automatic fallback were verified in the separate QA app; native AppKit acceptance and auxiliary-caret/IME refusal tests passed. The optimized Release code repeated Python/Java UI navigation, adoption, Undo/Redo, Esc and multi-caret refusal; artifact and signing checks passed. Independent review/publication remain gated; see `Release/NES030_ACCEPTANCE.md`. `Scripts/test-copilot-live-nes.sh` requires explicit opt-in and is intentionally excluded from unattended CI.

After NES -32601, automatic input/caret requests and manual NES are suppressed for that session. The active automatic-NES preference can still be turned OFF. “接続を確認” must succeed, or a new server connection must start, before another capability probe is allowed; merely changing automation does not reset unsupported status. The owner’s stored context-sharing consent is unaffected.
