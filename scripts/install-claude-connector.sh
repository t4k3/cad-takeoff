#!/usr/bin/env bash
# Builds the ftk-mcp bridge and prints how to register it in Claude Desktop / Claude Code.
# It does NOT modify any Claude configuration file on its own: pass --write-desktop-config
# to add the "fusion-takeoff" entry to Claude Desktop (a backup is made first).
set -euo pipefail
cd "$(dirname "$0")/.."
dest="${FTK_MCP_DIR:-$HOME/.local/bin}"
mkdir -p "$dest"
swiftc -O -o "$dest/ftk-mcp" Tools/ftk-mcp/main.swift
echo "✓ bridge installato: $dest/ftk-mcp"

cfg="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [[ "${1:-}" == "--write-desktop-config" ]]; then
  mkdir -p "$(dirname "$cfg")"
  [[ -f "$cfg" ]] && cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
  /usr/bin/python3 - "$cfg" "$dest/ftk-mcp" <<'PY'
import json, os, sys
path, binary = sys.argv[1], sys.argv[2]
data = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
data.setdefault("mcpServers", {})["fusion-takeoff"] = {"command": binary}
json.dump(data, open(path, "w"), indent=2)
PY
  echo "✓ Claude Desktop configurato ($cfg). Riavvia Claude Desktop."
else
  cat <<MSG

Claude Desktop — aggiungi in $cfg:
  "mcpServers": { "fusion-takeoff": { "command": "$dest/ftk-mcp" } }
(oppure rilancia questo script con --write-desktop-config)

Claude Code:
  claude mcp add fusion-takeoff -- "$dest/ftk-mcp"
MSG
fi
