#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../ModuleCache
swiftc -module-cache-path ../ModuleCache -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/CopilotDiagnostics.swift' \
 SemanticTests/CopilotDiagnosticsTests.swift -o ../SemanticTestBuild/copilot-diagnostics-tests
../SemanticTestBuild/copilot-diagnostics-tests
