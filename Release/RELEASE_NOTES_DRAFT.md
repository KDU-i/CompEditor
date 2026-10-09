# CompEditor — Java/Python semantic editor

**Draft: not published. Destination: KDU-i/CompEditor. Version/tag pending.**

Java and Python semantic completion, gray Tab-accept preview, symbol hover, error/warning underlines, safe Go to Definition/Go Back, active parameter hints, and explicitly selected current-document fixes/imports. No other language expansion. Persistent global/per-language OFF cancels requests and stops owned servers. Unsaved-buffer synchronization and native Undo are supported. Node/JDK/Pyright/JDT are bundled; app does not download dependencies or execute project build commands.

CompEditor is an unofficial modified fork, not endorsed by the CotEditor Project. Settings → General can switch About/application-menu labels to CotEditor immediately; Finder/Dock remain CompEditor. Bundle identity and saved data do not change. The unofficial-fork notice remains visible in both modes.

The original icon is used unchanged. Artwork attribution: CotEditor Project and original credited creators, including1024jp; material https://github.com/coteditor/CotEditor . Images retain CC BY-NC-ND4.0, https://creativecommons.org/licenses/by-nc-nd/4.0/ : retain attribution/links, share for noncommercial purposes, do not redistribute adapted artwork. Code retains Apache-2.0 and dependencies retain their separate licenses. See NOTICE and ARTWORK_ATTRIBUTION for full terms and warranty disclaimer. Matching dependency corresponding sources are supplied with the release.

Target: Apple Silicon arm64, macOS26+. Build/runtime tested on macOS27/Xcode27 beta; macOS26 runtime and Intel are unverified.

Known limits: Java Maven/Gradle import/autobuild disabled; saved Java source needed for tested hover/diagnostics. Python indexing/search-path discovery disabled; generic Pyright quickfixes may be empty and imports require actual analyzed candidates. Foreign/multifile/resource/command edits are refused; external/decompiled/stub definitions unsupported. Services increase CPU/memory and the bundled JDK increases download size. Full live GUI/OFF/relaunch checks remain incomplete.

Install/test in a separate local folder. Do not replace the installed official CotEditor. Close existing fork normally before launching another copy sharing the fork bundle ID. Publication account/repository: KDU-i/CompEditor. Version/tag and verified download links remain to be finalized.
