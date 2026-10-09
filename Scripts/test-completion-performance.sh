#!/bin/zsh
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
# Usage: appPath outputDirectory delayMilliseconds [baselineGitRevision]
set -euo pipefail
semantic_app="${1:A}"
semantic_output="${2:A}"
semantic_delay="$3"
semantic_revision="${4:-}"
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../ModuleCache
semantic_model='CotEditor/Sources/Semantic Completion/LSPModel.swift'
semantic_client='CotEditor/Sources/Semantic Completion/LSPClient.swift'
if [[ -n "$semantic_revision" ]]; then
  semantic_source=$(mktemp -d ../SemanticTestBuild/perf-source.XXXXXX)
  trap 'rm -r "$semantic_source"' EXIT
  git show "${semantic_revision}:$semantic_model" > "$semantic_source/Model.swift"
  git show "${semantic_revision}:$semantic_client" > "$semantic_source/Client.swift"
  semantic_model="$semantic_source/Model.swift"
  semantic_client="$semantic_source/Client.swift"
fi
swiftc -module-cache-path ../ModuleCache -swift-version 5 -parse-as-library \
  "$semantic_model" "$semantic_client" \
  'CotEditor/Sources/Semantic Completion/LSPSemanticDefaults.swift' \
  SemanticTests/CompletionPerformance.swift -o ../SemanticTestBuild/completion-performance
../SemanticTestBuild/completion-performance "$semantic_app" "$semantic_output" "$semantic_delay"
