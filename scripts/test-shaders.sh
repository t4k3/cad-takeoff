#!/bin/bash
# Viewport shaders: Shaders.metal compiled with the real Metal compiler (the app bundles
# default.metallib) and the section plane checked on an off-screen render.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-shaders.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun -sdk macosx metal -c App/Sources/UI/Viewport/Shaders.metal -o "$test_dir/shaders.air"
xcrun -sdk macosx metallib "$test_dir/shaders.air" -o "$test_dir/default.metallib"
xcrun swiftc -swift-version 6 -parse-as-library Tests/Shaders/Runner.swift -o "$test_dir/shader-tests"
"$test_dir/shader-tests" "$test_dir/default.metallib"
