#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/compeditor-expected.XXXXXX")
trap 'rm -rf "$build"' EXIT
"${SWIFTC:-swiftc}" -module-cache-path "$build/cache" -swift-version 5 -enable-bare-slash-regex -parse-as-library \
    CotEditor/Sources/Run/RunModel.swift CotEditor/Sources/Run/ExpectedOutput.swift SemanticTests/ExpectedOutputTests.swift -o "$build/tests"
"$build/tests"
# Swift 6.2.1 Linux's dynamic Observation library has an unresolved internal
# runtime symbol. Static stdlib uses the matching shipped runtime. macOS keeps
# the normal SDK/runtime linkage.
# Positional arguments expand safely when empty under Bash 3.2 + nounset.
set --
if [[ "$(uname -s)" == Linux ]]; then set -- -static-stdlib; fi
# AppKit picker is conditionally omitted on Linux; coordinator itself is production code.
"${SWIFTC:-swiftc}" -module-cache-path "$build/cache" "$@" -swift-version 6 -enable-bare-slash-regex -parse-as-library \
    CotEditor/Sources/Run/RunModel.swift CotEditor/Sources/Run/ExpectedOutput.swift \
    CotEditor/Sources/Run/ExpectedOutputSession.swift SemanticTests/ExpectedOutputSessionTests.swift -o "$build/session-tests"
"$build/session-tests"
cc -std=c11 -Wall -Wextra -Werror -pthread -c CotEditor/Sources/Run/RunProcess.c -o "$build/process.o"
"${SWIFTC:-swiftc}" -module-cache-path "$build/cache" -swift-version 5 -enable-bare-slash-regex -parse-as-library \
    -import-objc-header CotEditor/Sources/Run/RunProcess.h \
    CotEditor/Sources/Run/RunModel.swift CotEditor/Sources/Run/RunWorker.swift \
    CotEditor/Sources/Run/ExpectedOutput.swift SemanticTests/ExpectedOutputIntegrationTests.swift "$build/process.o" -o "$build/integration-tests"
"$build/integration-tests"
