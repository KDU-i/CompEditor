#!/bin/zsh
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
# LOCAL CANDIDATE ONLY: no signing, notarization, tags, uploads or publication.
set -euo pipefail
if (( $# != 6 )); then
  print -u2 'Usage: build-release-candidate.sh NEW_SOURCE_DIR NEW_BUILD_DIR CACHED_PACKAGES APPROVED_SERVERS NODE JDK'; exit 2
fi
semantic_source="${1:A}"; semantic_build="${2:A}"; semantic_packages="${3:A}"
semantic_servers="${4:A}"; semantic_node="${5:A}"; semantic_jdk="${6:A}"
if [[ -e "$semantic_source" || -e "$semantic_build" ]]; then
  print -u2 'Source/build destinations must be new; existing products are protected'; exit 2
fi
cd "${0:A:h:h}"
python3 Scripts/prepare-release-source.py --destination "$semantic_source"
cd "$semantic_source"
xcodebuild -project CotEditor.xcodeproj -scheme CotEditor -configuration Release \
 -derivedDataPath "$semantic_build" -clonedSourcePackagesDirPath "$semantic_packages" \
 -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
 -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
 ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO GCC_GENERATE_TEST_COVERAGE_FILES=NO \
 DEBUG_INFORMATION_FORMAT=dwarf SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO 'OTHER_LDFLAGS=$(inherited) -Xlinker -dead_strip_dylibs' \
 "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $semantic_source=/source -file-prefix-map $semantic_build=/build -file-prefix-map $semantic_packages=/packages -debug-prefix-map $semantic_source=/source -debug-prefix-map $semantic_build=/build -debug-prefix-map $semantic_packages=/packages" \
 "OTHER_CFLAGS=\$(inherited) -fdebug-compilation-dir=/source -ffile-prefix-map=$semantic_source=/source -ffile-prefix-map=$semantic_build=/build -ffile-prefix-map=$semantic_packages=/packages" -archivePath "$semantic_build/Candidate.xcarchive" clean archive
semantic_app="$semantic_build/Candidate.xcarchive/Products/Applications/CompEditor.app"
python3 Scripts/package-semantic-servers.py --app "$semantic_app" --servers "$semantic_servers" --node "$semantic_node" --jdk "$semantic_jdk"
python3 Scripts/finalize-private-app.py --app "$semantic_app"
python3 Scripts/finalize-release-candidate.py --app "$semantic_app" --packages "$semantic_packages"

python3 Scripts/audit-release-artifact.py --app "$semantic_app" --approvals Release/audit-reviewed-upstream.json --report "$semantic_build/artifact-audit.json"
