#!/bin/bash
# Viewport shaders: compiled with Metal (the app compiles them at runtime) and the section plane
# checked on an off-screen render.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-shaders.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library App/Sources/UI/Viewport/ShaderSource.swift Tests/Shaders/Runner.swift \
    -o "$test_dir/shader-tests"
"$test_dir/shader-tests"
