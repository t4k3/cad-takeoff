#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-mcp-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore \
    Packages/CADCore/Sources/CADCore/*.swift \
    -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    App/Sources/Integration/ToolBridge.swift \
    App/Sources/Integration/MCP/MCPServer.swift App/Sources/Integration/MCP/LocalHTTPTransport.swift \
    App/Sources/Model/DesignModel.swift App/Sources/Model/Tools/*.swift \
    Tests/MCPIntegration/Runner.swift -o "$test_dir/mcp-tests"
"$test_dir/mcp-tests"
