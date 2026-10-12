# Observable VS Code / Copilot parity plan

Public-source review: 2026-10-12. Implementation is local only. Exact service/proprietary-extension equivalence is not claimed. Existing source preimages are in ../Backups/BeforeVSCodeParity.

| Behavior | Previous CompEditor | Implemented observable behavior |
|---|---|---|
| Automatic request | 450ms, keyDown text changes | 50ms client debounce; edit/paste/delete/Undo/accept events, cancelled on superseding state |
| Explicit request | none | Trigger Inline Suggestion, macOS Option+Backslash; LSP triggerKind 1 vs automatic 2 |
| Candidate navigation | first item only | all eligible returned items; Option+] / Option+[; explicit fetch for alternatives |
| Range / suffix | end must equal caret | range may contain caret; insertion-only diff preserves original suffix; apply original range once |
| Deletions/rewrites | refused | refused as thin ghost; separate Next Edit Suggestions diff preview |
| Normal suggest | all pending/list states suppress AI | pending normal requests do not suppress; compatible selected-item extension can coexist; Tab prefers normal list |
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
