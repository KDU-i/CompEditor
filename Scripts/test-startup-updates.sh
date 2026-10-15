#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../ModuleCache
swiftc -module-cache-path ../ModuleCache -swift-version 6 -enable-bare-slash-regex \
  -emit-module -emit-library -module-name SemanticVersioning \
  Packages/EditorCore/Sources/SemanticVersioning/Version.swift \
  -o ../SemanticTestBuild/libSemanticVersioning.dylib \
  -emit-module-path ../SemanticTestBuild/SemanticVersioning.swiftmodule
swiftc -module-cache-path ../ModuleCache -swift-version 6 -parse-as-library \
  -I ../SemanticTestBuild -L ../SemanticTestBuild -lSemanticVersioning \
  -Xlinker -rpath -Xlinker @executable_path \
  CotEditor/Sources/Application/ForkUpdatePolicy.swift \
  CotEditor/Sources/Application/ForkStartupUpdate.swift \
  SemanticTests/StartupUpdateTests.swift -o ../SemanticTestBuild/startup-update-tests
../SemanticTestBuild/startup-update-tests
