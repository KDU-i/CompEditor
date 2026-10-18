#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../NES030ModuleCache
swiftc -module-cache-path "${PWD:h}/NES030ModuleCache" -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/LSPModel.swift' \
 'CotEditor/Sources/Semantic Completion/LSPClient.swift' \
 'CotEditor/Sources/Semantic Completion/LSPSemanticDefaults.swift' \
 SemanticTests/CopilotTests.swift -o ../SemanticTestBuild/copilot-tests
../SemanticTestBuild/copilot-tests "$PWD"
