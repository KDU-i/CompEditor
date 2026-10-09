#!/bin/zsh
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
semantic_app="${1:A}"
semantic_workspace="${2:A}"
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../ModuleCache
swiftc -module-cache-path ../ModuleCache -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/LSPModel.swift' \
 'CotEditor/Sources/Semantic Completion/LSPClient.swift' \
 'CotEditor/Sources/Semantic Completion/LSPSemanticDefaults.swift' \
 SemanticTests/RealAssistanceTests.swift -o ../SemanticTestBuild/real-assistance-tests
../SemanticTestBuild/real-assistance-tests "$semantic_app" "$semantic_workspace"
