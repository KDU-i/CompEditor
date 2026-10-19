#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(mktemp -d "${TMPDIR:-/tmp}/compeditor-run-core.XXXXXX")
trap 'rm -rf "$build"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pthread -c CotEditor/Sources/Run/RunProcess.c -o "$build/process.o"
"${SWIFTC:-swiftc}" -module-cache-path "$build/cache" -swift-version 5 -enable-bare-slash-regex -parse-as-library \
    -import-objc-header CotEditor/Sources/Run/RunProcess.h \
    CotEditor/Sources/Run/RunModel.swift CotEditor/Sources/Run/RunWorker.swift SemanticTests/RunCoreTests.swift \
    "$build/process.o" -o "$build/tests"
"$build/tests"
