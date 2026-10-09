# Local GitHub Release preparation

These scripts prepare review candidates without publishing or accessing credentials. The owner chose KDU-i/CompEditor, default CompEditor identity with an optional in-app CotEditor label, and the unchanged original icon. Preserve the original artwork's CC BY-NC-ND4.0 conditions and unofficial-fork attribution. See CHECKLIST.md, PUBLICATION.md and RELEASE_NOTES_DRAFT.md.

Use Xcode27 beta/Swift6.4 on the tested macOS27 builder, Python3.11+ and the already approved matching Node/JDK/server inputs. No global installs or runtime downloads. Supply new source/build paths; the builder refuses existing paths so Xcode cannot remove/overwrite current app products during name changes. Cached Swift dependencies must match Package.resolved. Dependencies/plugins still execute as part of the explicitly authorized build; services never run project build commands.

```sh
Scripts/build-release-candidate.sh NEW_SOURCE_DIR NEW_BUILD_DIR CACHED_SOURCE_PACKAGES APPROVED_EXTERNAL_SERVERS NODE_EXECUTABLE JDK_HOME
python3 Scripts/audit-release-artifact.py --app NEW_BUILD_DIR/Build/Products/Release/CompEditor.app --report artifact-audit.json
python3 Scripts/package-release-archive.py --input NEW_BUILD_DIR/Build/Products/Release/CompEditor.app --output CompEditor-unofficial-macos-arm64-LOCAL-CANDIDATE.zip
python3 Scripts/package-release-archive.py --input NEW_SOURCE_DIR --output semantic-fork-source-LOCAL-CANDIDATE.zip
```

The first command exports committed HEAD without .git, excluding dirty/untracked working files; the known local GUI error-fixture paths are generalized only in that copy. Added file-level comments and FORK_CHANGES.md disclose modifications while preserving legitimate upstream author attribution. JSON/generated project changes remain enumerated in that manifest. No Git history is rewritten. Confirm staged output as well as current source; a branch push would still disclose preserved history/author identities and old paths.

Build flags pin arm64, optimize Release, map build paths, remove unused dylib links and omit separate dSYMs. Finalization adds unofficial copyright text, preserves license copies and full JDT patch source, removes unlinked Sparkle.framework/SU keys, then strips native debug information. Debug-prefix maps alone did not remove all path records in this SDK, so stripping and artifact scanning are mandatory. No symbol files/logs/profiles/xattrs/UIDs enter the archive; ZIP timestamps are fixed. A SHA per file and whole archive is emitted. Bit-for-bit reproducibility across independent builders has not been demonstrated; preserve actual toolchain and input hashes.

Do not upload an archive merely because it exists. Scan candidates require review: upstream dependency binaries may contain their builders' paths or token-shaped strings. No automated high-entropy scanner proves absence of secrets. This release preparation is not a dependency vulnerability audit. Complete rights, corresponding-source, repository, runtime/Gatekeeper and final asset decisions first. Fork website/issues links use KDU-i/CompEditor; the upstream donation item is hidden. Original attribution remains and must not imply upstream endorsement.
