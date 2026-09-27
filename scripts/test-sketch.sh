#!/bin/bash
# Sketch drawing (SketchSession): snapping and ending lines, without the app's UI.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-sketch.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
core_sources=()
while IFS= read -r -d '' source; do core_sources+=("$source"); done < <(find Packages/CADCore/Sources/CADCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore "${core_sources[@]}" \
    -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    App/Sources/UI/Sketch/SketchSession.swift App/Sources/UI/Sketch/SketchSession+Constraints.swift \
    App/Sources/UI/Sketch/SketchSession+Edit.swift App/Sources/UI/Viewport/MatrixMath.swift \
    Tests/Sketch/Stubs.swift Tests/Sketch/Runner.swift -o "$test_dir/sketch-tests"
"$test_dir/sketch-tests"
