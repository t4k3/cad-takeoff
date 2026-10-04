#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ftk-mcp-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
core_sources=()
while IFS= read -r -d '' source; do core_sources+=("$source"); done < <(find Packages/CADCore/Sources/CADCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name CADCore \
    "${core_sources[@]}" \
    -emit-module-path "$test_dir/CADCore.swiftmodule" -o "$test_dir/libCADCore.dylib"
scripts/build-electronics-core.sh "$test_dir"
xcrun swiftc -swift-version 6 -parse-as-library -I "$test_dir" -L "$test_dir" -lCADCore -lElectronicsCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    App/Sources/Integration/ToolBridge.swift App/Sources/Integration/ToolRouter.swift App/Sources/Model/Electronics/*.swift \
    App/Sources/Integration/MCP/MCPServer.swift App/Sources/Integration/MCP/LocalHTTPTransport.swift \
    App/Sources/Model/DesignModel.swift App/Sources/Model/Tools/*.swift \
    Tests/MCPIntegration/Runner.swift -o "$test_dir/mcp-tests"
"$test_dir/mcp-tests"

# The stdio bridge with the app not running: the handshake comes from the saved file, nothing
# is launched (Ross 04/10: CAD Takeoff started with every Claude session); a tool call says the
# app is not running.
xcrun swiftc -swift-version 6 Tools/ftk-mcp/main.swift -o "$test_dir/ftk-mcp"
bridge_dir="$test_dir/bridge"; mkdir -p "$bridge_dir"
printf '%s' '{"supportedVersions":["2025-06-18"],"serverInfo":{"name":"fusion-takeoff","title":"CAD Takeoff","version":"t"},"instructions":"i","tools":[{"name":"scene_info","title":"Scena","description":"d","inputSchema":{"type":"object"}}]}' > "$bridge_dir/mcp-handshake.json"
replies=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"t"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scene_info","arguments":{}}}' \
  | FTK_MCP_DISCOVERY_DIR="$bridge_dir" "$test_dir/ftk-mcp")
REPLIES="$replies" python3 - <<'PY'
import json, os
lines = [json.loads(l) for l in os.environ["REPLIES"].splitlines() if l.strip()]
assert [l["id"] for l in lines] == [1, 2, 3], lines
assert lines[0]["result"]["serverInfo"]["name"] == "fusion-takeoff" and lines[0]["result"]["protocolVersion"] == "2025-06-18"
assert [t["name"] for t in lines[1]["result"]["tools"]] == ["scene_info"]
assert "non è in esecuzione" in lines[2]["error"]["message"]
print("PASS: bridge handshake without the app (initialize, tools/list from the saved file; tool call reported, no launch)")
PY

