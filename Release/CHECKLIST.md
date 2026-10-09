# Publication checklist — owner decisions pending

- [x] Owner chose repository **KDU-i/CompEditor**, standard app name CompEditor and optional in-app CotEditor labels. Current origin is upstream; never push there or through the unrelated CLI account. Repository creation/publication is not performed by preparation.
- [x] Owner chose the original unmodified icon. Preserve CC BY-NC-ND4.0 attribution, creator/material/license links, noncommercial distribution and no-adapted-artwork conditions; keep the unofficial-fork notice. See ARTWORK_ATTRIBUTION.md.
- [ ] Choose version/tag and review the final exact assets; do not publish unverified candidates.
- [ ] Confirm a privacy-safe **KDU-i** author/committer identity for new public commits. Existing fork commit identities do not match the expected KDU-i noreply identity; current Git configuration also differs. Do not push the private branch history as-is or silently rewrite it. Upstream legitimate attribution stays intact.
- [ ] Review local privacy report: tracked fixture generalized only in clean export; original working files and Git history retained. Review author/committer identities before any history push. Export contains no .git, logs or dirty GUI fixture changes.
- [ ] Review candidate binary scan, not just source; dSYM/debug logs/profiles/credentials excluded. Inspect candidate findings before upload. Heuristic absence of token patterns is not proof of no secrets.
- [x] Prepare pinned Temurin/OpenJDK full source and build scripts, exact JDT/plugin sources and distributed modified files. Retain notices and the source mapping manifest.
- [ ] Publish the prepared corresponding-source supplement beside the matching binary with equal access and an explicit source-download link.
- [ ] Verify actual downloaded-archive behavior on a clean supported Mac. Do not change OS security settings.
- [ ] Verify macOS26 runtime, complete app GUI/OFF/relaunch behavior and architecture expectations. Current bundle contains arm64 JDK; do not label universal/Intel compatible.
- [ ] Replace/disable upstream support/donation URLs as appropriate once fork destinations are supplied. Sparkle updater and its SU keys removed from candidate; no fork updater configured. No dedicated crash-upload configuration found in the bounded source scan; OS crash services are separate.
- [ ] Repeat audit after final identity or artifact changes; update hashes, review exact archive members and license/source files.
- [ ] Obtain explicit approval for the final repository/tag/assets and publication. Only then perform push/tag/Release upload.

Official references: Apache https://www.apache.org/licenses/LICENSE-2.0 ; CC artwork https://creativecommons.org/licenses/by-nc-nd/4.0/legalcode.en ; Temurin https://adoptium.net/docs/faq . Requirements are recorded for owner review, not a legal-clearance certification.
