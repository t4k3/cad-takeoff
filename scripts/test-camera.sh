#!/bin/bash
# Viewport camera: mouse rays and pans agree with the rendered view (also from below).
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-camera.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
core_sources=()
while IFS= read -r -d '' source; do core_sources+=("$source"); done < <(find Packages/CADCore/Sources/CADCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore "${core_sources[@]}" \
    -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    App/Sources/UI/Viewport/Camera.swift App/Sources/UI/Viewport/MatrixMath.swift \
    Tests/Camera/Runner.swift -o "$test_dir/camera-tests"
"$test_dir/camera-tests"
