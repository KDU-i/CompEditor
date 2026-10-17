# NES 0.3.1 acceptance record — review candidate

Baseline: public v0.3.0 commit 53327572ca71a6d0f10d1aa03aef59b2b757e759. Work is isolated on fix/nes-v031. The installed 0.3.0/build860 application is not replaced. The QA host uses a separate bundle identifier and synthetic documents.

## Evidence so far

- Debug application build passed. A native fixture compilation also covers the controller and AppKit presentation.
- Offline Copilot model/protocol, incremental history, consent/session, diagnostics privacy, update policy and startup update tests passed.
- New rebase/Tab tests cover matching/conflicting input, before/after target edits, minimization, UTF-16 emoji, canonical normalization, partial combining grapheme, LF/CRLF/CR proximity, adjacent/remote/continuing acceptance.
- Real-service probes using the official bundled 1.552.0 server and existing opaque authentication returned valid current-document NES in Python and Java (2/2). This is transport/provider evidence, not UI acceptance and not a requirement that a particular wording be predicted.
- Native application fixture passed four tests (16 payload variants plus policy/lifetime cases), then visual QA found a gutter overlap and added a final viewport regression. It is exercised with the same synthetic payload across Python/Java, LF/CRLF, insertion/replacement/deletion/multiline, Unicode/emoji, tabs and no trailing newline. It checks preview immutability, remote Tab jump, adoption caret, Undo/Redo, scrolling/resizing, rebase and reversed response ordering.
- Earlier native attempts failed at a fixture path-escaping error and inactive QA host; these are not counted as passes. IME/multi-caret application refusal and basic preview/Undo tests passed in those runs. A later full native run passed all four tests, including real RPC-count suppression after Undo. Physical IME interaction remains unverified; synthetic marked-text and multi-caret refusal passed.

## Release preparation

1. Commit reviewed source and record its tree SHA. Export using `Scripts/prepare-release-source.py`; never build a distribution from the QA identity or uncommitted files.
2. Run `Scripts/build-release-candidate.sh` with new source/build directories and approved cached packages, semantic servers, Node/JDK and checksum-pinned official Copilot server. Keep coverage disabled and anonymous path mapping.
3. Confirm Info.plist 0.3.1/861, original identity, required signed-feed/archive flags, existing public key and exact approved latest feed URL. Run artifact audit and strict nested/ad-hoc code-signature verification.
4. Package matching app/source/corresponding sources with existing audit scripts. Reuse the existing dependency supplement only after verifying pinned components are unchanged; rename/version its manifest accurately.
5. Use official Sparkle tools and the existing dedicated Keychain account to sign archive and appcast without exporting private material. Verify with the shipped public key, check fixed v0.3.1 links, version/build/length/hash and source-tree provenance together. No key/permission changes.
6. Return the exact tree, candidate hashes and all residuals for independent review. Wait for the parent's explicit release instruction before merge/tag/publication/latest-feed change. Installation is excluded.

## Residuals

Provider internals, cross-file transactions, arbitrary multi-hunk structure and VS Code settings/experiments remain intentionally outside the single-primary-edit host implementation. The native focused-hover feature and a VS Code-style Tab-focus setting do not exist in this host. Full native popup/hover interaction, physical IME, arbitrary soft-wrap/RTL and simultaneous service+UI behavior are not claimed. Do not describe this record as proof of every VS Code feature or prediction matching.

## Twenty-item outcome table

PASS means the stated host behavior is covered by the named evidence, not all settings/providers in VS Code. Intentional differences and unverified cases prevent a blanket “all differences fixed” claim.

|No.|Outcome|Implementation and evidence / residual|
|---|---|---|
|01|意図した差|Keep ordinary inline-first/fallback and active-NES ownership; policy/protocol tests pass. The official standalone server does not expose VS Code joint-provider scheduling.|
|02|意図した差|Keep existing cancellable 50ms debounce and duplicate suppression. Provider latency/cache policy is not mirrored.|
|03|意図した差|Keep observed pre-edit/current-document history; incremental and live probes pass. No workspace-wide or cross-file history collection.|
|04|PASS|Empty single-caret moves retain NES; native test moves within displayed candidate; selected text/marked text/multiple carets still refuse.|
|05|PASS|Target-anchored rendering and navigation; current URI/version validation. Native foreign-document refusal passes; no cross-file adoption.|
|06|PASS|Green inline insertion, compact red/green replacement, deletion strike, stacked/wide difference surfaces; synthetic image evidence.|
|07|PASS|Inline green insertion at target, navigation arrow; source and Undo unchanged by preview.|
|08|PASS|Red old word and compact green replacement directly near target; visual evidence.|
|09|PASS|16 Java/Python × LF/CRLF × insertion/replacement/deletion/multiline payloads, emoji/tab/no final newline; one primary range remains intentional.|
|10|PASS|Adjacent-line/direct and remote/jump Tab, consecutive-visible policy, indentation precedence; native key tests plus policy tests.|
|11|BLOCKED|Native completion list wins in routing code; indentation tested. Full native popup/focused-hover interaction not exercised. Host hover cannot become key; Tab-focus setting absent.|
|12|PASS|Native Esc dismissal, no stale adoption; composition guards preserved.|
|13|PASS|Native before-target rebase; matching prefix/conflict/after-target/combining/normalization model tests; strict UTF-16 snapshots.|
|14|PASS|Native caret folded at final minimized difference, including deletion and common suffix; no selected replacement text.|
|15|PASS|Native separate Undo/Redo; automatic NES enabled and actual mock RPC count unchanged after Undo; fresh edit/explicit requests resume.|
|16|意図した差|Post-accept NES request preserved; continuing-visible Tab policy added. Provider prefetch/cache and NES word/line partial acceptance not mirrored.|
|17|PASS|Native marked-text and auxiliary/multiple-caret application refusal pass. Physical IME conversion remains unverified.|
|18|BLOCKED|Scroll/resize retention and responsive preview reconstruction pass in the native matrix. Final actual offscreen/gutter regression is pending at this snapshot.|
|19|PASS|Independent option persistence/policy tests and native unsupported-server toggle/reprobe tests pass; authentication unchanged.|
|20|PASS|Protocol stale version/cancellation and native reversed A/B response/document-switch rejection pass; existing empty/unsupported/timeout distinctions retained.|

## Candidate distribution evidence

An initial local Release candidate built from tree a8d6d3651a78569080bb4d519f7b2c8062936fcc passed artifact audit: 68,987 files, 92 Mach-O binaries, 197 nested archives. Its app and feed declare 0.3.1/build861; archive and feed signatures used the existing dedicated Sparkle Keychain account, and the archive signature was independently verified with only the shipped public key. That initial archive is superseded by the gutter correction and must not be published. Rebuild/re-sign the reviewed final tree before any publication. No release, tag, merge, latest-feed update or installation has occurred.
