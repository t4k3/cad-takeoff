#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-tools.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
core_sources=()
while IFS= read -r -d '' source; do core_sources+=("$source"); done < <(find Packages/CADCore/Sources/CADCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore \
    "${core_sources[@]}" \
    -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    App/Sources/Integration/ToolBridge.swift \
    App/Sources/Model/DesignModel.swift App/Sources/Model/Tools/*.swift \
    Tests/AssistantTools/Runner.swift -o "$test_dir/assistant-tests"
"$test_dir/assistant-tests"
