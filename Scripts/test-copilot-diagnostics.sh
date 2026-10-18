#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../NES030ModuleCache
swiftc -module-cache-path "${PWD:h}/NES030ModuleCache" -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/CopilotDiagnostics.swift' \
 SemanticTests/CopilotDiagnosticsTests.swift -o ../SemanticTestBuild/copilot-diagnostics-tests
../SemanticTestBuild/copilot-diagnostics-tests
