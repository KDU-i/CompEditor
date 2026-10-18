# Observable VS Code / Copilot parity plan

Public-source review: 2026-10-12. The table and validation below record the earlier 0.2.0 behavior. Version 0.2.1 supersedes normal-suggest priority as described immediately below. Exact service/proprietary-extension equivalence is not claimed. Existing source preimages are in ../Backups/BeforeVSCodeParity.

| Behavior | Previous CompEditor | Implemented observable behavior |
|---|---|---|
| Automatic request | 450ms, keyDown text changes | 50ms client debounce; edit/paste/delete/Undo/accept events, cancelled on superseding state |
| Explicit request | none | Trigger Inline Suggestion, macOS Option+Backslash; LSP triggerKind 1 vs automatic 2 |
| Candidate navigation | first item only | all eligible returned items; Option+] / Option+[; explicit fetch for alternatives |
| Range / suffix | end must equal caret | range may contain caret; insertion-only diff preserves original suffix; apply original range once |
| Deletions/rewrites | refused | refused as thin ghost; separate Next Edit Suggestions diff preview |
| Normal suggest | earlier 0.2.0 used compatible selected-item extension and normal-list Tab priority | 0.2.1 owner policy: displayed-current AI dismisses ordinary UI and owns Tab; loading/empty/failure keeps ordinary completion available |
| Partial accept | none | Command+Right accepts next word; Accept Next Line menu; cumulative UTF-16 provider feedback |
| Full accept / dismiss | Tab / Esc | retain, correct ownership/version and separate Undo stops |
| Language identity | file extension and syntax disagree | one syntax-first languageId resolver for request/display; saved/unsaved consistent |
| Other languages | Java/Python only | opt-in broader language modes, separate context-scope explanation; no workspace synchronization |
| Multi-line preview | floating full candidate box | inline ghost with temporary layout gap; long-candidate preview fallback |
| IME / selection | mostly suppressed | no preview or interception during composition/nonempty selection; safe multi-cursor refusal retained |
| NES | absent | explicit official textDocument/copilotInlineEdit; separate diff/target jump/accept; auto fallback opt-in |

Implementation order: model/range/language, protocol triggers/partial feedback, controller actions and normal suggest coexistence, nonmutating inline layout, NES UI, deterministic tests, real synthetic fixtures, normal-app UI and atomic delivery.

References (behavior observed, not copied editor assets):
- https://code.visualstudio.com/docs/editing/ai-powered-suggestions
- https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/inlineCompletions/browser/controller/commands.ts
- https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/inlineCompletions/browser/controller/inlineCompletionsController.ts
- https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/inlineCompletions/browser/model/computeGhostText.ts
- https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/inlineCompletions/browser/model/inlineCompletionsModel.ts
- https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.18/language/inlineCompletion.md
- https://github.com/github/copilot-language-server-release/blob/1.552.0/README.md

VS Code's MIT notice remains in RuntimeNotices/VSCode-MIT-LICENSE.txt and app ThirdPartyNotices. Official server MIT/third-party notices remain bundled. New code uses original Swift/AppKit implementation rather than copying Monaco assets or private extension internals. Unsupported/untested differences will be recorded after validation.


Validation completed (2026-10-12):
- Debug build and 17 AppKit tests passed, including temporary multiline layout, unchanged text/Undo during preview, suffix weaving and partial Undo.
- Core/mock integration, offline Copilot/diagnostics, and 25 parity protocol/model checks passed; cancellation/version/language identity, half-open diagnostics, Unicode/CRLF, original-range safety and current-document indentation covered.
- Normal CompEditor UI with local deterministic peer: manual request, two alternatives and both cycle shortcuts; multiline inline preview; word/line partial acceptance; full acceptance and separate Undo stops; string-midpoint quote preservation; Next Edit diff, Tab jump, second Tab acceptance and one Undo; compatible selected Pyright completion + AI extension, with Tab accepting only ordinary print first; nonempty selection suppressed AI. Fixtures were restored with Undo.
- Official macOS arm64 1.552.0 live stdio: new nonconfidential Python and Java arithmetic fixtures each returned one valid inline candidate. Public textDocument/copilotInlineEdit responded with an empty edits list, so API support is verified but real NES candidate production/acceptance remains unverified. Cancellation and stopped-client synchronization refusal passed. Only these new fixtures were sent after explicit user approval; no signIn/OAuth calls or credential logging.

Known limits:
- This is observable editor behavior compatibility, not an assertion of complete equivalence to VS Code's proprietary extension or service ranking, latency, number of alternatives, or NES model decisions.
- Multiple carets deliberately refuse AI suggestions. IME composition guard is implemented; physical IME and multi-caret interaction stress have not been manually verified in this pass.
- Word boundaries use a generic Unicode identifier expression, rather than every VS Code language's word-definition regex.
- Soft-wrapped/very long preview geometry is not exhaustively verified. Inline layout reserves at most 200 new lines; longer candidates use a scrollable preview. Vertical writing refuses previews.
- Additional language modes require separate explicit context-sharing opt-in; real service tests in this pass cover Java/Python only.
- NES is experimental and opt-in for automatic fallback. Empty live response is not treated as unsupported, while -32601 disables only NES.
- Unsigned Debug app was tested locally; Developer ID signing, notarization and public distribution are outside this local task.

## 0.2.1 owner policy and session restoration

VS Code’s default normal suggest popup priority is retained here only as historical research. CompEditor 0.2.1 deliberately gives the displayed-current AI preview ownership of the suggestion UI and Tab. The old selected-item-extension model tests do not establish this new UI policy; the independent offline GUI matrix does. Partial acceptance retains the remaining current preview and separate Undo stops. Deferred automatic requests do not replace a visible current preview.

Startup restores existing official authentication with checkStatus. No new OAuth completion runs automatically. Context sharing requires explicit enable/consent; remembering that consent is optional and OFF by default. The editor stores only booleans. Normal exit uses shutdown/exit, not signOut. See [release details](Release/V0.2.1.md).

## 0.3.0 NES validation in progress

The empty-response observation above is historical. In the 0.3.0 investigation, the same official 1.552.0 server returned genuine next edits after observing a local variable rename in synthetic Python and Java documents. The provider has a no-edit-history early exit and starts its observable workspace lazily. Minimal incremental changes and seeding from the real pre-edit snapshot replace the earlier whole-document update path. No candidate is fabricated or relabeled from ordinary completion.

Offline coverage now includes independent persisted automation flags, NES with inline automation off, fallback after inline filtering, current URI/version validation, no-op refusal, UTF-16/CRLF edit reconstruction, one-time history initialization, and the fixed-metadata diagnostics boundary. On a separate 0.3.0 QA app, an actual Python service edit displayed its before/after diff, Tab moved then adopted it, and one Undo restored the pre-adoption text. Automatic zero-inline to NES fallback also displayed a real proposal. A native 2-test suite now passes preview/Undo/Redo and IME/auxiliary-caret adoption refusal. A distinct auxiliary caret is refused by actual position rather than a permissive count check. The final optimized Release code also passed real Python and Java diff display, Tab navigation/adoption, Undo/Redo, Esc dismissal and multi-caret request refusal. Automatic NES displayed a Java proposal with inline automation off. Distribution/signature audits passed; independent review and publication remain gated. See Release/NES030_ACCEPTANCE.md for observations and limits.

## 0.3.1 scope correction (unreleased)

Current NES behavior and the original twenty comparison items are mapped to pinned primary sources in [Release/NES031_SCOPE_AUDIT.md](Release/NES031_SCOPE_AUDIT.md). The earlier sections remain version-specific history. Current joint/NES requests do not use the old fixed 50 ms delay; independent requested documents retain bounded history. Known cross-document navigation, derived hunks and Tab-focus ownership are host behavior, not unavailable provider features. Word/line partial adoption belongs to ordinary ghost completion, not NES. New exact-tree native/service/CI/distribution evidence and independent review are required before publication.
