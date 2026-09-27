#!/bin/bash
# The on-device assistant (Foundation Models): tool schemas convert; FTK_LIVE_FM=1 also runs a
# real request when Apple Intelligence is on (not in CI: the model's answers vary).
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-fm.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
core_sources=()
while IFS= read -r -d '' source; do core_sources+=("$source"); done < <(find Packages/CADCore/Sources/CADCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore "${core_sources[@]}" \
    -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
electronics_sources=()
while IFS= read -r -d '' source; do electronics_sources+=("$source"); done < <(find Packages/ElectronicsCore/Sources/ElectronicsCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name ElectronicsCore "${electronics_sources[@]}" \
    -emit-module-path "$test_dir/ElectronicsCore.swiftmodule" -o "$test_dir/libElectronicsCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore -lElectronicsCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    App/Sources/Integration/ToolBridge.swift App/Sources/Integration/ToolRouter.swift App/Sources/Model/Electronics/*.swift \
    App/Sources/Model/DesignModel.swift App/Sources/Model/Tools/*.swift \
    App/Sources/Integration/Assistant/AssistantProvider.swift App/Sources/Integration/Assistant/AssistantSession.swift \
    App/Sources/Integration/Assistant/AppleIntelligenceProvider.swift \
    Tests/AppleIntelligence/Runner.swift -o "$test_dir/fm-tests"
"$test_dir/fm-tests"
