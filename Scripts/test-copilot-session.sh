#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../NES030ModuleCache
swiftc -module-cache-path "${PWD:h}/NES030ModuleCache" -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/LSPModel.swift' \
 'CotEditor/Sources/Semantic Completion/LSPClient.swift' \
 'CotEditor/Sources/Semantic Completion/CopilotSession.swift' \
 SemanticTests/CopilotSessionTests.swift -o ../SemanticTestBuild/copilot-session-tests
../SemanticTestBuild/copilot-session-tests "$PWD"
