#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../SemanticTestBuild ../NES030ModuleCache
swiftc -module-cache-path "${PWD:h}/NES030ModuleCache" -swift-version 5 -parse-as-library 'CotEditor/Sources/Application/ForkUpdatePolicy.swift' SemanticTests/UpdaterPolicyTests.swift -o ../SemanticTestBuild/updater-policy-tests
../SemanticTestBuild/updater-policy-tests
