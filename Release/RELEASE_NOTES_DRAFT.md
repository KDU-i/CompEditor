# CompEditor v0.2.0

Local release candidate; not published. Version 0.2.0 / build 854 (greater than the previous build 853). Apple Silicon arm64, macOS 26+. Build and runtime verified on macOS 27 / Xcode 27 beta.

Adds a Japanese “Check for Updates…” menu/settings button backed by pinned Sparkle 2.10.0. Manual checks only, automatic installation and system profiling disabled. HTTPS fork-only feed/download URLs, signed feeds and archive verification before extraction are required. Current candidate has no approved fork public key/feed and fails safely without network or installation; production update delivery remains blocked pending owner signing/feed setup. Failed checks can be retried and Sparkle handles cancellation according to installation stage. Updates are deferred for unsaved documents; no automatic rollback of an installed update is promised. Updater-less older versions require one manual installation to gain this mechanism.

Adds official GitHub Copilot inline suggestions using the bundled macOS stdio language server 1.552.0 and public GitHub device sign-in flow. First-use context-sharing explanation and explicit enabling are required; OFF stops document synchronization and the owned server. Credentials remain opaque to the host editor. Java/Python are the initial scope; other language modes require a separate opt-in.

Supports automatic and manual suggestions, alternative cycling, word/line partial acceptance, suffix-preserving multiline ghosts, native Undo, and normal LSP candidate-list priority for Tab. Red-underlined diagnostics show error details on hover, including overlapping diagnostics and severity/source/code. Existing Java/Python navigation, parameter hints and current-document fixes remain available.

Experimental Next Edit Suggestions use the official public API and separate Before/After preview, target jump and acceptance. Mock UI/protocol are verified; the real server returned no NES candidate in the synthetic probe. Real candidate production/acceptance is not verified. No claim of complete proprietary VS Code extension/service equivalence.

Validation: AppKit 18 tests, core/mock 114 checks, Copilot/diagnostic 19 checks parity 25 checks and updater-policy 23 checks passed before release packaging. Normal UI covered cycling, word/line/full acceptance, Undo, quote preservation, ordinary completion coexistence and mock NES. New nonconfidential Java/Python fixtures each received a real inline candidate with user permission. Physical diagnostic hover was confirmed.

Limits: multiple carets safely refuse AI; physical IME/multi-caret stress and exhaustive wrapped/long geometry remain unverified. macOS 26 runtime, Intel, clean-machine downloaded ZIP/Gatekeeper behavior, Developer ID signing and notarization remain unverified. Distribution candidate is unsigned/ad hoc only, with no developer identity. Java project autobuild and Python workspace indexing remain disabled.

Unofficial CotEditor fork, not endorsed by the CotEditor Project. Original icon/artwork and attribution retained unchanged under CC BY-NC-ND 4.0; distribute noncommercially. Host code retains Apache-2.0; Copilot server retains MIT and required third-party notices; bundled dependencies keep their licenses and matching corresponding sources. See NOTICE.md, THIRD_PARTY.md and ARTWORK_ATTRIBUTION.md.

Assets to publish together after owner approval: arm64 application ZIP, exact reviewed host-source ZIP, matching dependency corresponding-source ZIP, provenance and SHA256SUMS. No remote push/tag/Release creation is performed by this preparation.
