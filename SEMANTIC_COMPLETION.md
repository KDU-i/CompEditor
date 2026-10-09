# CompEditor naming update

The owner-selected repository is KDU-i/CompEditor. New builds are CompEditor.app. Settings → General → Use CotEditor for in-app labels changes About and app-menu labels immediately; Finder/Dock remain CompEditor. The preference persists across launches. Bundle ID dev.local.SemanticEditor and SemanticEditor support/cache domains are deliberately unchanged; no data migration or runtime bundle rewriting occurs. About always identifies this as an unofficial fork. Original artwork is unchanged under CC BY-NC-ND4.0; see Release/ARTWORK_ATTRIBUTION.md.

For a developer build use Scripts/build-semantic-editor.sh and open ../CompEditorBuild/Build/Products/Debug/CompEditor.app. The new build directory preserves earlier task-local app products. For release builds use the six explicit new-directory arguments documented in Release/README.md. Node/JDK/server inputs are supplied explicitly and copied; no global installation occurs.

The following describes the earlier semantic implementation and prototype verification history. Earlier CotEditor.app paths and private appearance decisions are historical; current identity/build instructions above supersede them.

---

# SemanticEditor development fork

Based on official CotEditor commit `efd522f9fc9362a5211aef528b96a87dcad11335`.
This private local fork provides **Java and Python semantic completion, hover, diagnostics, definitions, parameter hints and explicit fixes**, with persistent global and per-language OFF controls.
It is not an official CotEditor release. No server is downloaded or installed by the app.

## Build and run locally

The app preserves the upstream **macOS 26 deployment target**. The build was verified on macOS 27 with Xcode 27 beta / Swift 6.4. Actual execution on macOS 26 has not been tested. The pinned upstream checkout uses item-based SwiftUI dialogs marked macOS 27-only by this SDK; a small bridge to older isPresented/presenting APIs avoids raising the product minimum. Optional existential/opaque type spellings were mechanically parenthesized for the installed compiler. A temporary macOS 27-only build was used to diagnose these upstream compatibility issues, then reverted. The stable 7.1.1 release also targets macOS 26; a macOS 15 product would need a separately validated backport to the 6.2.6 host.

```sh
Scripts/build-semantic-editor.sh
open ../Build/Build/Products/Debug/CotEditor.app
```

The app target uses `Configurations/SemanticEditor.xcconfig`. Build dependencies remain pinned by the upstream project. Their local Swift build plugins run during compilation; the script skips their interactive validation. This is an unsigned, unsandboxed **local development build**, with identifier `dev.local.SemanticEditor`. It does not change system security settings. Xcode signing teams, provisioning profiles, and credentials are not used. No automatic installation or application replacement is performed.

Settings and support files use the fork's own defaults domain and `Application Support/SemanticEditor`; upstream CotEditor preferences, support folders, and iCloud containers are not migrated. At the user's explicit request, this private local prototype keeps the original unmodified CotEditor icon and visual appearance. The private build is named CotEditor.app and uses the original upstream AppIcon assets, as requested. Its task-local build path and separate internal bundle ID/support storage protect the installed CotEditor. The earlier SemanticEditor.app resource path has been reconstructed for its still-running process; close them normally yourself when ready, then open the new CotEditor.app path. Upstream artwork license restrictions remain; this is not permission for external distribution.

## CotEditor appearance in the private fork

The new output is `../Build/Build/Products/Debug/CotEditor.app`, with CotEditor as the executable, raw/localized bundle name and display name. Debug/Release and test-host paths agree; packaging targets this app. Internal identifier `dev.local.SemanticEditor`, preference domain and `SemanticEditor` support/cache directories remain separate from the installed application. The original upstream `AppIcon.icon` assets are unchanged from the pinned base; the completed app includes AppIcon.icns and its compiled catalog. The unsigned macOS27 beta build produced a blank native file-icon render with generated CFBundleIconName metadata. The finalizer removes that name lookup and explicitly selects the same original AppIcon.icns; native file-icon rendering then displayed the green pen correctly, without cache reset. About's source uses the bundle name and application icon. The previous process was not closed. Xcode unexpectedly removed the earlier SemanticEditor.app product as stale during the rename; its path/resources were reconstructed from the new build, with its old product/executable metadata, while the same process remained running. This is a reconstructed resource bundle, not a byte-identical backup of the old binary. User documents and installed CotEditor were not changed.

`../identity-build.log` records successful build/package; `../identity-verification.log` checks raw/localized names and native icons. `../IdentityReview/fork-workspace-after.png` is a native icon render, not a Dock or application screenshot. The user-supplied Library screenshot could not be materialized: preparation succeeded, but the supported helper received HTTP403 even after newly preparing the transfer; no readable image was produced. Actual attached pixels and the running Dock/About/Finder windows remain unverified. No Accessibility bypass, icon-cache reset, process termination or installed-app replacement was performed. Original artwork remains restricted to the user's private prototype preference; this does not authorize public distribution.

## Open and use: no setup dialog

The local build bundles the already approved Node v24.14.1, Temurin JDK 25.0.2, Pyright 1.1.414 and Eclipse JDT LS 1.61.0 under `Contents/Resources/SemanticServers`. Executable paths are resolved relative to the running app. Opening a `.java` or `.py` file requires no descriptor import, trusted-folder picker or language enable step. An untitled document uses its selected Java/Python syntax and an isolated virtual buffer. Servers start lazily on editor focus, a qualifying edit or a manual semantic request.

Fresh fork preferences enable semantic completion, Java, Python and automatic suggestions. Existing explicit OFF preferences survive migration. **Semantic Completion → Enable Semantic Completion**, **Enable Java/Python**, and **Show Automatically While Typing** persist across launches. **Turn All Off** persists the global OFF state and stops owned servers immediately. Turning one language off, closing a document window or quitting also stops clients and cancels pending results; other enabled services restart lazily. Closing or quitting preserves preferences.

Typing waits 60 ms with a warm service and paced input, 110 ms during rapid input, or 120 ms before startup, after an advertised trigger (for example `.`) or the **first identifier character**. The semantic path uses its own eligibility rule, independent of CotEditor’s ordinary word-completion minimum. Empty text/whitespace and a receiverless dot do not issue requests. **Complete Semantically** (Command–Shift–Space) requests manually. Up/Down explicitly selects a candidate; Return/Tab then inserts it. Escape cancels. An unselected Return retains ordinary editor behavior. Tab explicitly accepts a current gray preview when one is visible; without a preview or explicit row selection it retains ordinary editor behavior. **Server Status…** reports detected failures. Missing resources fail closed; the app downloads nothing and does not fall back to project commands.

Workspace selection uses the saved file's containing folder, or the nearest language-specific marker within six ancestors. Marker metadata is inspected; scripts and build files are never executed. Home, Documents/Desktop/Downloads and volume roots, hidden directories, Library and system/runtime trees are refused as analysis roots. Untitled files, broad-folder files and symlink files use private cache workspaces and virtual URIs; buffer text is sent over stdio without writing it to those URIs. Java configuration/data are writable private copies under `Caches/SemanticEditor/LSP/java`.

Java automatic Gradle/Maven import, builds and build-configuration updates remain disabled. Safe standalone/unmanaged Java works; Maven/Gradle classpath richness is unavailable. Python auto-search paths and indexing are disabled and diagnostics are limited to open files. Pyright can still read ordinary analysis configuration and imports in the selected narrow workspace. Trusted bundled servers run with normal user permissions and a small environment; this is not a server sandbox.

## Prepare a developer build

`Scripts/build-semantic-editor.sh` builds the app, runs `Scripts/package-semantic-servers.py`, then finalizes private icon metadata with `Scripts/finalize-private-app.py`. Packaging copies existing approved inputs only and includes their license notices. It never downloads or installs dependencies. The current builder inputs are task-local `../ExternalServers`, existing `/usr/local/bin/node`, and `/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home`. Another builder can pass `--app`, `--servers`, `--node`, and `--jdk` explicitly to the packaging script. End users do not configure these paths; the finished app owns portable relative paths. The current private app is about 736 MB because it includes Node and a full JDK. CPU/memory cost increases when a service runs.

Server distributions and runtime versions are deliberate build inputs. Preserve their licenses/notices when replacing them. Adding languages remains outside this Java/Python-only scope: `LSPLanguage`, fixed resource mapping and the menu are the maintained integration boundary. Earlier JSON descriptor examples and the descriptor harness remain development tools; descriptors are no longer imported by the app UI.

## Protocol and editing behavior

`LSPModel.swift` contains JSON framing, descriptor validation and UTF-16 range validation. `LSPClient.swift` owns stdio transport, initialize, full/incremental document synchronization, completion and optional resolve. `SemanticCompletionController.swift` owns persistent switches, asynchronous requests and AppKit integration. `LSPSemanticDefaults.swift` resolves bundled runtimes and conservative workspaces.

A snapshot is sent on every manual trigger, including unsaved changes. Incremental-only servers receive one full-range edit against the previous snapshot. Candidate responses and resolved items are checked against the current text, primary/multiple selection, document identity, focus, cancellation and configuration generation. Save As or a user edit while waiting prevents insertion. Text edits and nonoverlapping additional edits are applied atomically through CotEditor's undo-aware replacement, with explicit caret placement and an Undo action named Semantic Completion.

Only plain text completion is supported. Snippets, arbitrary commands, invalid/overlapping ranges, non-UTF-16 servers, unsupported synchronization and completion-list defaults are refused. JDT's exact `java.completion.onDidSelect` bookkeeping attachment is ignored so its plain completions remain usable; it is never executed. No `workspace/executeCommand` is sent; server-initiated workspace edits are refused. No snippet placeholders are inserted as text. Candidate preparation scores at most 5,000 server items on a worker, validates at most 1,000 ranked results and displays at most 100 usable candidates. Exact/case-sensitive prefixes rank before case-insensitive prefixes and subsequence matches; server preselect, sortText and original order break ties. Resolved edit validation also runs on a worker. Imported text is normalized to the document line endings before atomic insertion. Responses have bounded framing, an eight-chunk queue that stops the server on overload, and a 15-second request timeout. Off synchronously terminates exact owned processes, cancels pending requests and prevents queued startup escaping termination. Failed/stalled individual clients have bounded termination escalation independent of stdin writes.

Manual and typing-triggered completion share a nonactivating native list. The current box adapts pinned MIT Code OSS width/theme defaults: opaque light/dark backgrounds, one-pixel border, 2 pt corners, 22 pt rows, rectangular blue selection, aligned kind/name/signature columns, overlay scrollbar and bounded detail/documentation footer. SF Symbols remain original to macOS; there is no copied VS Code artwork. Actual metadata is displayed; documentation is neither invented nor eagerly fetched for every item. See `RuntimeNotices/README.md` for the exact reuse and license details.

The best append-compatible completion is drawn in neutral gray at the caret. This is drawing only: no text-storage attribute, document text, save content or Undo entry is added. Typed prefixes are removed. Preview requires one plain edit ending at the caret, an identical replacement prefix, a single-line suffix of at most 256 UTF-16 units, no additional edits, and no following visible source on that line. Forward replacements, multiline/snippet/import edits and mid-line cases remain available through the alternatives box rather than being visually misrepresented. Right-to-left or vertical editor layouts suppress inline preview. Preview is clipped to the visible editor; gray follows the actual editor background brightness.

Up/Down explicitly selects a row; Return only accepts a selected row. Tab accepts a selected row or a current gray preview. Ghost acceptance resolves the candidate asynchronously and rechecks that the resolved edit is still the same append-only suffix; changed edits/imports are refused through that path. Explicitly selected popup candidates retain full validated editing behavior. Escape cancels pending work and dismisses until the next qualifying edit. IME, navigation/selection, focus/window/language/document changes and OFF invalidate or suppress previews. Undo/programmatic edits/paste do not schedule suggestions. Automatic requests cache only routing/server preparation for an unchanged document identity; manual requests rediscover the root. Candidate results are not reused across changed text. Identical synchronized snapshots skip redundant didChange/version updates.


## Hover parameters and types

Keep global Semantic Completion and the desired Java/Python language enabled. Move the pointer onto a class, function or method identifier in the active document window and pause for 350 ms. A nonactivating native tooltip shows the server's signature, parameter names/types and available documentation. This works independently of Show Automatically While Typing; global/per-language OFF disables hover and stops the same owned servers used for completion. Hover does not alter document text, selection or Undo.

The client requests LSP hover at the UTF-16 symbol position. When the source actually has an opening parenthesis after that symbol, it also requests signature help at that parenthesis. It displays existing hover immediately and then adds actual server signatures; optional signature errors/timeouts retain the hover and completion client. No constructor arguments are inferred for a class declaration whose server hover lacks them. Verified Pyright 1.1.414 returns function/method parameters, types and docs, plus constructor arguments for the test class declaration and constructor call. Verified JDT LS 1.61.0 returns Java method and constructor-call signatures/docs for saved Java files; class-name hover can describe only the class.

JDT LS currently returns empty hover for our disk-absent virtual Java document fixtures, although those fixtures support completion. Save a Java file with its intended name to obtain tested hover behavior. The app does not secretly materialize untitled buffers or overwrite saved documents. Pyright hover was verified with disk-absent virtual Python documents. All requests synchronize unsaved editor text; saved Java tests verify a parameter rename appears without changing the saved file.

JDT LS 1.61's [hover/signature handlers](https://github.com/eclipse-jdtls/eclipse.jdt.ls/blob/v1.61.0/org.eclipse.jdt.ls.core/src/org/eclipse/jdt/ls/core/internal/handlers/JDTLanguageServer.java) omit the lifecycle-job wait used by definition. Tests initially reproduced stale parameters immediately after didChange. For a synchronized Java snapshot not yet inspected, the client therefore sends a read-only definition request before hover/signature help. Its links are ignored; it waits for document updates without navigating, fetching files, executing commands or invoking a project build. Unchanged inspected snapshots reuse that barrier state; canceled barriers remain pending. This is specific to the bundled JDT version and adds a request after a Java edit.

Pointer movement to another symbol, editing, selection changes, Save As, scrolling, window/focus changes, mouse selection/drag, composition, document close and OFF cancel or invalidate pending hover. Results must still match the exact snapshot, document identity, symbol, language and cancellation generations. Completion panels/in-flight completion, obscured windows, selection/multiple carets, IME and vertical layout suppress hover. The tooltip stays inside the document window/screen and does not cover the hovered symbol/pointer.

All metadata is bounded inert plain text (4096 UTF-16 units, at most 12 displayed lines): code-fence markers and direction-control characters are removed, but Markdown/HTML/links are not interpreted. There are no clickable command links, remote images or automatic fetches. Very long metadata is truncated. Cold server startup and Java analysis can extend the initial 350 ms wait.

Hover evidence: task-level `hover-core.log` contains mock transport, Unicode/CRLF offsets, absent info, stale snapshot/pointer stamps, delayed cancellation and signature-error fallback checks. `hover-real-servers.log` runs the bundled Pyright/JDT servers, method/constructor metadata, actual unsaved parameter changes and no disk changes. `hover-appkit.log` covers native tooltip plain text, glyph hit testing and existing completion/Undo/IME tests. `hover-{java,python}-{light,dark}.png` are component renders using actual server metadata, **not full application screenshots or end-to-end pointer tests**. Full external GUI automation remains blocked by the existing Accessibility denial; no alternate control method or permission change was used.


## Diagnostics, definitions, parameter hints and fixes

All four features use the existing global and Java/Python switches. Global OFF clears cards/underlines, cancels pending work and synchronously stops exact owned server processes. Re-enabling starts analysis for the focused supported document. Diagnostics update after focus or edits (including paste/Undo) with a 450 ms debounce, independently of typing suggestions. Error ranges are drawn with red dotted underlines and warnings with orange dotted underlines. Drawing changes no text-storage attributes, saved content or Undo entries. **Show Diagnostics…** lists current messages. Editing clears old markings immediately; only matching protocol version, local edit revision, snapshot and document identity can repopulate them. Parsing runs on a worker. Unversioned notifications are refused.

Pyright already publishes versioned diagnostics. JDT LS1.61 does not; the app's copied server therefore carries the narrowly pinned [diagnostic-version patch](ServerPatches/jdtls-1.61/README.md). The patch captures a successfully synchronized version and open-session identity under JDT's reconcile lock before analysis, rejects changed/failed/closed/reopened sessions and publishes the captured version. Actual Java/Python error and warning severities, unsaved correction/clear and an injected invalid Java edit were tested. Original external server inputs remain untouched. The builder now also needs `javac` in the explicitly supplied JDK; nothing is installed or downloaded by packaging. Full original/modified EPL source, input hashes and patch script are bundled with notices. Unpatched/replaced JDT servers without versioned diagnostics will not display Java underlines.

**Go to Definition** requests actual LSP locations at the caret. One result jumps directly; several results require selection. Same-buffer definitions preserve unsaved text. Cross-file targets must be regular local `.java`/`.py` sources within the current conservative workspace, at most 4 MB, with no hidden relative path or symlink. File checks run on a worker; snapshot, caret, focus, language and identity are rechecked after opening. Existing documents are reused rather than reloaded. Edited destination documents are refused because the server's destination range may be stale. **Go Back** retains at most 30 weak-view entries and returns only if the source snapshot still matches. Actual same-file and cross-file Java/Python definitions were tested. External libraries, Pyright `.pyi` stubs and JDT `jdt:` decompiled targets are currently unsupported; no network fetch or decompilation is invoked.

Typing within a bounded open-call context requests actual signatureHelp after 180 ms, at the **current caret** rather than the start of the function name. The server selects the signature and active parameter. Offset labels or plain parameter labels drive native bold/background highlighting, with invalid UTF-16 boundaries refused. The nonactivating card sits above the caret while completion sits below, and is suppressed when it would cover the caret or no current signature exists. Java's supported `signatureHelp.enabled` setting is explicitly enabled. The typing-auto switch controls both completion and typing parameter hints; **Show Parameter Hints** invokes hints manually. Selection/navigation/Escape, edits, composition, focus, scrolling, window changes, close and OFF cancel pending hints. Actual second-argument highlighting was verified for Java and Python; no parameter list is guessed from a lexical count.

**Quick Fix / Add Import…** requests actual code actions with current diagnostics, waiting at most three seconds for current analysis on the asynchronous client. It lists only validated current-document edits. You must select a menu item to apply it. No action is silently applied; there is no executeCommand call. `java.apply.workspaceEdit` is only unwrapped as edit data, never executed. Arbitrary command actions, file creation/rename/delete, annotated changes, foreign/multiple-document edits, stale/malformed versions, invalid UTF-16 ranges and overlaps are rejected atomically. Other open/unsaved documents and disk files remain untouched. Source snapshot/caret/focus/identity are rechecked before one native replacement and Undo operation; line endings/caret are preserved appropriately.

Java supplies real quick fixes, including Import ArrayList and Add all missing imports; the harness validates its actual current-document edits and refuses foreign-file Create Class actions. Pyright OSS has far fewer generic text fixes than Pylance; tested generic action lists were empty. Import assistance uses actual resolved completion additionalTextEdits for an already typed identifier. Its primary completion edit must preserve that identifier exactly, and only the extra import edits are applied. A real HelperWidget import from an analyzed local helpers.py module was verified. With indexing/search-path discovery disabled, symbols in unanalysed modules (for example bare Path in an otherwise blank file) may have no import suggestion. The app reports unavailable safe actions instead of inventing imports or creating stubs, installing packages or running server/project commands.

Evidence: `assistance-core.log` runs fragmented **mock** diagnostics/actions, stale/unversioned/ABA rejection, cancel/timeout, unsafe URI/file/version/resource/command boundaries, import-only preservation and UTF-16 highlighting. `assistance-real.log` uses the **actual bundled** JDT/Pyright servers for all four features, current error/warning/clear, same/cross-file definitions, active second parameter, actual import edits and Java fix/fault probes; source fixtures remain unchanged on disk. `assistance-appkit.log` covers 11 native tests including drawn diagnostics without storage/Undo mutations, highlighted labels, and the exact selected-action application helper's Undo/Redo with an untouched unsaved sibling. `diagnostics-native-synthetic.png` is a native component test using synthetic severities, not an actual application screenshot. `assistance-build.log` records the final private build/package. Full pointer/key/menu/window interaction remains unverified because the prior Accessibility denial was not bypassed.


## Verification

```sh
Scripts/test-semantic-core.sh
```

This compiles the exact Foundation protocol sources, tests framing/UTF-16/edit rejection, and runs a deliberately fragmented **mock** stdio server. It is not a real Pyright/JDT LS test. See task-level `core-tests.log`, `fork-build.log`, and any UI test evidence recorded with the implementation. A mock proves protocol boundaries, not semantic quality or compatibility with every server release.

## Distribution

No public repository push, release, signing, notarization, paid service, or installed CotEditor replacement is included. Original fork code is Apache-2.0; the adapted VS Code style defaults retain MIT copyright/license notices. Bundled runtimes/servers retain their separate licenses. Original upstream notices and LICENSE remain. Upstream image assets have a separate CC BY-NC-ND license. This local development app must not be treated as a ready distributable: resolve artwork/trademark permissions or replace/rebrand those resources, choose a production bundle identity, and arrange signing/notarization before any proposed distribution. The user requested original appearance specifically for private use; nothing was published or distributed externally. The upstream sandboxed configuration cannot reliably launch these arbitrary external runtimes; an App Store sandbox would need a separate helper/bundling/security-scoped-access design and explicit compatibility validation.

## Actual acceptance evidence

- `../auto-core-tests.log`: exact Foundation sources and fragmented mock server pass; this is mock/protocol evidence.
- `../auto-real-server-tests.log`: real Pyright 1.1.414 and JDT LS 1.61.0 initialize, semantic members, resolve and validated edits pass. Both analyze a newly added unsaved method while the disk text stays unchanged, advertise `.` and return semantic members with LSP triggerKind 2. JDT caps its empty-prefix response at 50 items; typing a prefix narrows that server-side result.
- `../auto-appkit-tests.log`: real AppKit tests cover non-key panel, marked-text key pass-through, candidate light/dark row rendering, and the editor test that validates primary replacement plus additional import as one Undo/Redo operation.
- `../automatic-gui-acceptance.md` and earlier `../gui-acceptance.md`: native GUI on macOS 27 validates real Java/Python typing-triggered and manual suggestions, insertion and Undo. Initial setup failure handling was checked separately.
- `../auto-build.log`: final unsigned macOS 26 deployment build succeeds on the available macOS 27 host. Actual macOS 26 runtime behavior remains untested.

Run real transport acceptance explicitly with the approved installed distributions:

```sh
Scripts/test-real-servers.sh ../ExternalServers/real-servers.json ../ExternalServers/acceptance
```

Pyright was installed with task-local prefix/cache and `--ignore-scripts --no-audit --no-fund`. The official JDT milestone archive and SHA-256 were downloaded, hash verified, and archive paths/types checked before extraction (141 safe entries). SHA-256: `338e7e73d61836651ba2453919a0d34fa763eb4e7c03342092309bffb8934c64`. Original downloaded distributions remain in `ExternalServers`; app-owned JDT writable state now lives in its isolated cache. See `../server-install-evidence.txt`.

## Zero-setup checkpoint evidence

- `../zero-setup-build.log`: unsigned local build succeeds, approved runtimes packaged into the app.
- `../zero-setup-core.log`: fresh/migrated preference behavior, persisted OFF, bounded routing, sensitive roots, stable untitled URI, missing resources and manifest traversal checks, plus the fragmented **mock** protocol harness pass.
- `../zero-setup-real-servers.log`: **real bundled** Pyright/JDT LS analyze virtual buffers that do not exist on disk; member completion, resolve, dot triggers and new unsaved methods pass. Run `Scripts/test-real-servers.sh ../Build/Build/Products/Debug/CotEditor.app ../SemanticTestBuild/bundled-acceptance` in an empty test directory.
- `../zero-setup-relocated.log`: real bundled servers pass after moving a task-local app clone to a different path containing spaces.
- `../zero-setup-package.log`: synthetic packaging fixtures verify cycle and external-symlink rejection; no runtime/server is executed by this test.
- `../zero-setup-appkit.log`: four native AppKit tests pass (panel focus, marked-text keys, candidate row rendering, and atomic additional-edit Undo/Redo).
- The earlier GUI evidence applies to the previous popup checkpoint. Fresh-launch/relaunch GUI acceptance of the new setup-free path remains unverified: the current execution context has no CUA tool and native AppleScript Accessibility access is denied (`-1719`). No security permission was changed. Preference reconstruction tests are not a substitute for actual GUI relaunch tests.

## Inline-preview and latency checkpoint

`../ghost-build.log` is the final build; `../ghost-core.log` covers ranking, prefix/Unicode/CRLF/boundary rejection, adaptive delay, unchanged synchronization, mock resolve-added imports, and pending-request cancellation. `../ghost-real-servers.log` verifies actual bundled Java/Python ranking and append suffixes against resolved edits, plus semantic members, triggers and unsaved changes. `../ghost-appkit.log` contains six native tests including visual-state storage/Undo isolation and the shared gray renderer. `../ghost-package.log` checks synthetic packaging boundaries.

Measured on this Mac against the same bundled servers, with 12 warm repeats of the same snapshot per language:

| Measured request path | Before | After |
| --- | ---: | ---: |
| Java, delay + transport median | 321.2 ms | 72.0 ms |
| Python, delay + transport median | 328.3 ms | 69.7 ms |
| Java, transport median without delay | 5.1 ms | 5.7 ms |
| Python, transport median without delay | 5.6 ms | 0.4 ms |

The large improvement is the policy change from 300 to 60 ms for paced warm typing. Java transport has no demonstrated speedup; Python repeated unchanged requests improve by avoiding redundant changes. Cold Java initialization still takes about 1.2 seconds, followed by analysis; startup is not instantaneous. Small samples and server caching influence these numbers. Logs: `../ghost-performance-{before,after}.log` and `../ghost-performance-{before,after}-raw.log`. The harness uses real servers and Task.sleep to model the actual policy; these are request-path measurements, **not end-to-end native popup/ghost display measurements**. Ranking/layout/rendering are outside that timed interval.

`../suggestions-vscode-{java,python}-{light,dark}.png` render production row/surface components with ranked real server metadata. `../ghost-preview-{light,dark}.png` use the production gray drawing helper with a synthetic string. They are component previews, not full app GUI screenshots. Full GUI typing, Tab/Escape, scrolling, focus, and relaunch validation remain blocked by unavailable CUA and denied Accessibility access; no bypass or permission change was attempted.

Reproduce the measured old/new request policies using fresh output directories (run sequentially, avoiding concurrent builds):

```sh
Scripts/test-completion-performance.sh ../Build/Build/Products/Debug/CotEditor.app ../SemanticTestBuild/recheck-before 300 3a0f0729c
Scripts/test-completion-performance.sh ../Build/Build/Products/Debug/CotEditor.app ../SemanticTestBuild/recheck-after 60
```

The optional revision compiles that local commit's exact protocol/transport sources; it does not change the checkout. Use delay `0` to measure transport alone.

## First-character automatic-trigger correction

The semantic eligibility helper previously required `prefix.count >= 3`; that was the direct cause of the three-character behavior. It now accepts the first letter/underscore of an identifier. Both automatic request gates (before request and after server startup) use this helper, so the candidate box and gray preview share the corrected path. CotEditor's separate ordinary word completion keeps its independent three-character minimum. An advertised dot after a receiver triggers without any following identifier; the normal 60–120 ms debounce and cold server startup still apply.

`../first-character-core.log` covers one/two/three-character eligibility for Java/Python, mock eligibility→request→ranked box/ghost, advertised dot, empty/whitespace/receiverless-dot refusal and existing protocol protections. `../first-character-real-servers.log` verifies actual bundled Java/Python one/two/three-character member and root-variable candidates with eligible gray previews, dot triggerKind2, resolve and unsaved sync. Java's variable label is `value : String`; its actual filterText/label format is used for validation. `../first-character-appkit.log` retains six native tests; `../first-character-build.log` is the final local build. Independent source review found no remaining blocking threshold or safety regression.

No full GUI verification is implied; supported GUI access remains unavailable and the previous Accessibility denial was not bypassed. Relaunch the private built app normally to load the correction; the existing running app and user-edited fixture are preserved.
