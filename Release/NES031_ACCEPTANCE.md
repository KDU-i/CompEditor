# NES 0.3.1 acceptance record — in progress

Baseline: public v0.3.0 commit 53327572ca71a6d0f10d1aa03aef59b2b757e759. Work is isolated on fix/nes-v031. The installed 0.3.0/build860 application is not replaced. The QA host uses a separate bundle identifier and synthetic documents.

## Evidence so far

- Debug application build passed. A native fixture compilation also covers the controller and AppKit presentation.
- Offline Copilot model/protocol, incremental history, consent/session, diagnostics privacy, update policy and startup update tests passed.
- New rebase/Tab tests cover matching/conflicting input, before/after target edits, minimization, UTF-16 emoji, canonical normalization, partial combining grapheme, LF/CRLF/CR proximity, adjacent/remote/continuing acceptance.
- Real-service probes using the official bundled 1.552.0 server and existing opaque authentication returned valid current-document NES in Python and Java (2/2). This is transport/provider evidence, not UI acceptance and not a requirement that a particular wording be predicted.
- Native application fixture is being exercised with the same synthetic payload across Python/Java, LF/CRLF, insertion/replacement/deletion/multiline, Unicode/emoji, tabs and no trailing newline. It checks preview immutability, remote Tab jump, adoption caret, Undo/Redo, scrolling/resizing, rebase and reversed response ordering.
- Earlier native attempts failed at a fixture path-escaping error and inactive QA host; these are not counted as passes. IME/multi-caret application refusal and basic preview/Undo tests passed in those runs. Complete final native results remain required.

## Release preparation

1. Commit reviewed source and record its tree SHA. Export using `Scripts/prepare-release-source.py`; never build a distribution from the QA identity or uncommitted files.
2. Run `Scripts/build-release-candidate.sh` with new source/build directories and approved cached packages, semantic servers, Node/JDK and checksum-pinned official Copilot server. Keep coverage disabled and anonymous path mapping.
3. Confirm Info.plist 0.3.1/861, original identity, required signed-feed/archive flags, existing public key and exact approved latest feed URL. Run artifact audit and strict nested/ad-hoc code-signature verification.
4. Package matching app/source/corresponding sources with existing audit scripts. Reuse the existing dependency supplement only after verifying pinned components are unchanged; rename/version its manifest accurately.
5. Use official Sparkle tools and the existing dedicated Keychain account to sign archive and appcast without exporting private material. Verify with the shipped public key, check fixed v0.3.1 links, version/build/length/hash and source-tree provenance together. No key/permission changes.
6. Return the exact tree, candidate hashes and all residuals for independent review. Wait for the parent's explicit release instruction before merge/tag/publication/latest-feed change. Installation is excluded.

## Residuals

Provider internals, cross-file transactions, arbitrary multi-hunk structure and VS Code settings/experiments remain intentionally outside the single-primary-edit host implementation. Pixel-level rendering and all key-routing branches must pass final native/visual acceptance before describing application-fixable differences as complete.
