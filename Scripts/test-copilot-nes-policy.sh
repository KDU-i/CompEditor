#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../NES030TestBuild ../NES030ModuleCache
swiftc -module-cache-path "${PWD:h}/NES030ModuleCache" -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/LSPModel.swift' \
 'CotEditor/Sources/Semantic Completion/LSPClient.swift' \
 'CotEditor/Sources/Semantic Completion/CopilotSession.swift' \
 SemanticTests/CopilotNESPolicyTests.swift -o ../NES030TestBuild/copilot-nes-policy-tests
../NES030TestBuild/copilot-nes-policy-tests
