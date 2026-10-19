# CE-050: reuse NES display differences (#7)

Based on main `65e2b30c59151940f77fd29e96727cdd64d7d07c`. Implementation only; the v0.4.0 version/build bump belongs to integration.

## Design and scope

`SemanticNextEditDisplayData` holds immutable CRLF-normalized before/after text and preview-local UTF-16 removal/insertion ranges. It uses the existing policy and its unchanged 50 ms budget. Lone CR behavior, one-hunk tint behavior and conservative fallback remain unchanged.

Each candidate owns a lazy `SemanticNextEditDisplayCache`; ghosts retain that slot. Candidate identity and the existing controller's editor/file/revision checks bound its ownership. Changing `Candidate.edit` (including rebase and partial adoption) resets the slot; foreign/project navigation candidates also reset on revision changes. Transplanting a foreign candidate into its destination resets the slot because navigation text becomes replacement text even when `edit` itself is unchanged. A new candidate gets a fresh slot even if its text equals another candidate's. Caret-only presentation retains the slot. Height measurement and panel construction use the same immutable data. No per-frame text comparison/hash, global cache, shared NSView, algorithm change or asynchronous diff work was added. Existing source-hunk coordinates remain separate.

Existing CotEditor editor fonts, line metrics, native panel/scroll views, side-by-side threshold, colors, accessibility labels and keyboard routing are retained. No UI text was added or changed. Reasonable Japanese localization follows the existing app conventions; no localization resources need to change for this internal optimization. Runner/UI work for #8 is untouched.

## Cloud checks (Linux, 2026-10-19)

- `git diff --check`: pass.
- Tree-sitter Swift syntax parse of the five changed/added Swift files: no error or missing nodes. This is syntax validation, **not Swift type checking or a build**. Parser dependencies were isolated in `/tmp/ce050-parser`.
- `python3 -B Scripts/test-copilot-diagnostics-privacy.py`: pass.
- `python3 -B Scripts/test-release-artifact-audit.py`: 23 tests pass (temporary anonymous fixtures only; no distribution artifact created).
- `python3 -B SemanticTests/PackageTests.py`: both packaging boundary checks pass.
- `zsh Scripts/test-copilot-nes-policy.sh` and `zsh Scripts/test-copilot-nes-rebase.sh`: unavailable, `swiftc` not installed.
- `xcodebuild -version`: unavailable, `xcodebuild` not installed.
- Git-conditions script cannot run without its compiled Swift probe; invoking it without that required argument reports `IndexError`. No Git-conditions pass is claimed.

No macOS/Swift tests, device QA, performance results or screenshots are claimed from this Linux environment.

## Added automated coverage (must run on macOS)

`SemanticNextEditDisplayTests` checks normalized UTF-16 reconstruction for CRLF, lone CR, empty text, deletion, multiple hunks, emoji/combining characters, and zero-budget fallback. It constructs 100 narrow/wide, font/color-varying surfaces with exactly one display preparation, verifies stacked/side-by-side layout, distinguishes equal-text owners/revisions, and checks release.

The existing exclusive `CopilotNESAcceptanceTests.syntheticPayloadsUseRealControllerKeysAndViewport` fixture now runs 100 actual resize/bounds/move presentation cycles. It checks a single display preparation, retained ghost/panel, and zero additional candidate RPCs. Its existing real-edit rebase/caret path now verifies a fresh slot for rebase and retained slot for caret-only presentation. The cross-file fixture checks the actual rendered navigation text before first Tab, then distinct destination cache identity, destination before/after data (`Hello` → `Bye`), actual rendered `NSTextView` content (`Bye`), and one destination preparation across repeated presentation before second-Tab adoption. This covers the P2 navigation-cache transplant regression found in initial head `b7d1ef85df9371e2c542ec7ca5560c10881f8432`. Existing acceptance/cancel/Undo/Redo, IME/multicursor, stale response, multiwindow and split fixtures continue to apply.

## Required parent-coordinated macOS verification

1. Build and run the existing CI commands on the exact PR head (including `SemanticNextEditDisplayTests` and `SemanticCompletionTests`), then the exclusive native fixture with parallel testing disabled:
   ```sh
   xcodebuild test -scheme CotEditor COMPEDITOR_USAGE_ENDPOINT= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc -skipPackagePluginValidation -skip-testing:Tests/CopilotNESAcceptanceTests
   xcodebuild test-without-building -scheme CotEditor COMPEDITOR_USAGE_ENDPOINT= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc -skipPackagePluginValidation -parallel-testing-enabled NO -only-testing:Tests/CopilotNESAcceptanceTests
   zsh Scripts/test-copilot-nes-policy.sh
   zsh Scripts/test-copilot-nes-rebase.sh
   ```
2. Record `NES_DISPLAY_CACHE_PASS presentationUpdates=100 displayPreparations=1 additionalCandidateRPCs=0`; keep display computations distinct from ordinary candidate/hunk generation. Check new candidates, candidate cycling, rebase, partial inline adoption, typing, Undo/Redo and Esc; ensure obsolete slots release on cancellation/document close.
3. With a long multiline NES, scroll vertically/horizontally and move the window. Resize repeatedly through the 740-point preview threshold; confirm both layouts, wrapping, colored ranges, reserved height and gutter arrow without losing the candidate or preparing the display diff again. Repeat in separate equal-text documents and split views, verifying independent native views.
4. Compare screenshots against existing CotEditor UI at normal/narrow widths and Light/Dark appearances, with font/theme/accent changes. Move between backing scales if available. Verify panel bounds, baseline, source visibility, focus and redraw. Include Japanese app-language coverage; existing technical English labels may remain where natural.
5. Verify keyboard Tab navigation/adoption, Esc cancellation, normal completion priority and one-step Undo/Redo. Exercise physical Japanese IME composition and multiple carets. Check VoiceOver label/content discovery and that previews never take editor keyboard focus.

Parent coordinates independent review and required device use. No merge, issue closure, release/tag, deployment, installed-app overwrite or authentication change is authorized by this PR.
