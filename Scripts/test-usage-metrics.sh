#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../ModuleCache
swiftc -module-cache-path ../ModuleCache -swift-version 6 -strict-concurrency=complete -parse-as-library \
  'CotEditor/Sources/Application/ForkUsageMetrics.swift' SemanticTests/UsageMetricsTests.swift \
  -o ../SemanticTestBuild/usage-metrics-tests
# Optional arguments are compiled Info.plist paths; inspection never launches the application.
../SemanticTestBuild/usage-metrics-tests "$@"
