#!/usr/bin/env bash
# Fusion 360 add-in: export with a stand-in Fusion API, then open the .ftk with CADCore.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-fusion-addin.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 Tests/FusionAddIn/fake_fusion.py "$test_dir"
core_sources=()
while IFS= read -r -d '' source; do core_sources+=("$source"); done < <(find Packages/CADCore/Sources/CADCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore \
    "${core_sources[@]}" -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore \
    -Xlinker -rpath -Xlinker "$test_dir" Tests/FusionAddIn/Check.swift -o "$test_dir/check"
"$test_dir/check" "$test_dir/Staffa v3.ftk"
