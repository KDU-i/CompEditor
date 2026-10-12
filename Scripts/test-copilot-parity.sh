#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../ModuleCache
swiftc -module-cache-path ../ModuleCache -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/LSPModel.swift' \
 'CotEditor/Sources/Semantic Completion/LSPClient.swift' \
 'CotEditor/Sources/Semantic Completion/LSPSemanticDefaults.swift' \
 SemanticTests/CopilotParityTests.swift -o ../SemanticTestBuild/copilot-parity-tests
../SemanticTestBuild/copilot-parity-tests "$PWD"
