#!/bin/bash
# CIRCUITI's tools (App/Sources/Model/Electronics) against the electronics engine, without the UI.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-circuits.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find Packages/ElectronicsCore/Sources/ElectronicsCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name ElectronicsCore "${sources[@]}" \
    -emit-module-path "$test_dir/ElectronicsCore.swiftmodule" -o "$test_dir/libElectronicsCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lElectronicsCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    App/Sources/Model/Electronics/*.swift App/Sources/Integration/ToolBridge.swift Tests/Circuits/*.swift -o "$test_dir/circuit-tests"
"$test_dir/circuit-tests" "App/Resources/Circuiti/Esempio circuito.ftkc" "Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/Library"
