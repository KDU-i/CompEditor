#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${COMPEDITOR_RUN_LIVE_NES:-}" != 1 || $# != 1 ]]; then
 print 'Requires COMPEDITOR_RUN_LIVE_NES=1 and an official copilot-language-server path'; exit 2
fi
mkdir -p ../NES030TestBuild ../NES030ModuleCache
swiftc -module-cache-path "${PWD:h}/NES030ModuleCache" -swift-version 5 -parse-as-library \
 'CotEditor/Sources/Semantic Completion/LSPModel.swift' \
 'CotEditor/Sources/Semantic Completion/LSPClient.swift' \
 'CotEditor/Sources/Semantic Completion/CopilotSession.swift' \
 SemanticTests/CopilotLiveNESTests.swift -o ../NES030TestBuild/copilot-live-nes-tests
../NES030TestBuild/copilot-live-nes-tests "$1"
