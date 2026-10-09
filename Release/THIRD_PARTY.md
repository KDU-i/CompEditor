# Third-party inventory and source obligations

| Component | Pinned input | License / supplied location |
|---|---|---|
| CotEditor | efd522f9fc9362a5211aef528b96a87dcad11335 | Apache-2.0 code; CC BY-NC-ND4.0 images; CotEditor-LICENSE.txt and NOTICE.md |
| Node | 24.14.1 existing builder binary | Node MIT plus included third-party notices; SemanticServers/Node-LICENSE.txt |
| Pyright OSS | 1.1.414 | MIT; SemanticServers/pyright/pyright/LICENSE.txt; no Pylance |
| Eclipse JDT LS / plugins | 1.61.0 with pinned core JAR and private diagnostic patch | EPL-2.0 and plugin-specific licenses in JARs/features; ThirdPartyNotices/JDT-Diagnostic-Patch original+modified sources, script and SHA manifests |
| Temurin OpenJDK | 25.0.2+10, aarch64 | GPLv2 + Classpath Exception and third-party terms; SemanticServers/jdk/legal (all files retained) |
| VS Code styling reference | 651237c307271b300329a7039913da7e5676afa5 | MIT; VSCode-MIT-LICENSE.txt |
| Swift/tree-sitter dependencies | Package.resolved revisions | Per-component LICENSE/COPYING/NOTICE copied into SwiftDependencies; manifest included |

Temurin installed release metadata identifies source https://github.com/adoptium/jdk25u at commit prefix 9e3c947043a4 and build scripts https://github.com/adoptium/temurin-build at 458965074606f027bd5afce2cfd5c1055dea0438. Supplier release: https://github.com/adoptium/temurin25-binaries/releases/tag/jdk-25.0.2%2B10 . The local corresponding-source supplement now contains both pinned complete repository archives, including native code and build scripts, and all installed JDK legal files. Provide this supplement beside the binary download with the same access and an explicit source-download link. A Java-only src.zip or an upstream pointer is not the chosen source distribution mechanism. No source offer is made on another party's behalf.

The local supplement contains complete pinned repository archives or exact Maven source JARs for 113 of 114 bundled JDT plugin JARs, plus the original and modified diagnostic-patch files copied from the actual candidate. The remaining flexmark-util JAR contains no class files; its original aggregate POM is supplied and its component modules have exact source JARs. A machine-readable manifest distinguishes failed original requests from successful replacements, with per-file SHA-256 and binary-to-source mapping. The Java compiler source repository moved to eclipse-jdtls; the exact original commit is retained.

Retain EPL-2.0 for Eclipse components, LSP4J, Logback and Jakarta annotation/servlet components; m2e workspace CLI and JUnit retain EPL-1.0. Jakarta Inject uses Apache-2.0. Use JNA's expressly offered Apache-2.0 alternative rather than its LGPL alternative. JetBrains decompiler source headers identify Apache-2.0; its exact source JAR is supplied. MIT/BSD/Apache components still require their attribution/license notices even where corresponding source is not required. No dependency is relicensed as the host's Apache-2.0 code. Retain source supplement and its licenses beside every matching binary distribution; local preparation does not establish a public download endpoint or certify legal compliance.
