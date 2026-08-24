#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
TEST_BINARY="$SOURCE_DIR/.build/shuffle-bag-tests"

mkdir -p "$SOURCE_DIR/.build"
xcrun swiftc \
  -warnings-as-errors \
  "$SOURCE_DIR/ShuffleBag.swift" \
  "$SOURCE_DIR/ShuffleBagTests.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"
