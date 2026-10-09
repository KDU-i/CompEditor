#!/bin/zsh
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project CotEditor.xcodeproj -scheme CotEditor -configuration Debug \
  -derivedDataPath ../CompEditorBuild -clonedSourcePackagesDirPath ../Build/SourcePackages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
# Approved local dependencies are copied into this app only; nothing is downloaded.
python3 Scripts/package-semantic-servers.py
python3 Scripts/finalize-private-app.py
