#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-3mf.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
mkdir -p build/3mf
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore \
    Packages/CADCore/Sources/CADCore/*.swift \
    -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore \
    -Xlinker -rpath -Xlinker "$test_dir" Tests/ThreeMF/Fixture.swift -o "$test_dir/fixture"
"$test_dir/fixture" build/3mf/TwoColorParts.3mf
python3 Tests/ThreeMF/verify.py build/3mf/TwoColorParts.3mf
