#!/usr/bin/env python3
"""Launch the official private MCP tunnel through Fusion Takeoff's shared stdio bridge.
No secrets in argv, generated files or printed commands. No public listener.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

PROFILE = 'fusion-takeoff'
DOCS = 'https://developers.openai.com/api/docs/guides/secure-mcp-tunnels'


def default_bridge():
    candidates = [Path('/Applications/FusionTakeoff.app/Contents/MacOS/ftk-mcp'),
                  Path.home() / 'Applications/FusionTakeoff.app/Contents/MacOS/ftk-mcp',
                  Path(__file__).resolve().parents[1] / 'build/DerivedData/Build/Products/Debug/FusionTakeoff.app/Contents/MacOS/ftk-mcp',
                  Path.home() / '.local/bin/ftk-mcp']
    return next((p for p in candidates if p.is_file()), candidates[0])


def command(action, executable, bridge, tunnel_id=None):
    if action == 'configure':
        if not tunnel_id or not re.fullmatch(r'tunnel_[A-Za-z0-9_-]{8,128}', tunnel_id):
            raise ValueError('Specificare --tunnel-id con l ID effettivo dalle impostazioni OpenAI.')
        return [executable, 'init', '--sample', 'sample_mcp_stdio_local', '--profile', PROFILE,
                '--tunnel-id', tunnel_id, '--mcp-command', shlex.join([str(bridge)])]
    if action == 'doctor':
        return [executable, 'doctor', '--profile', PROFILE, '--explain']
    if action == 'run':
        return [executable, 'run', '--profile', PROFILE]
    raise ValueError('Azione sconosciuta.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'configure', 'doctor', 'run'])
    parser.add_argument('--tunnel-id')
    parser.add_argument('--bridge', type=Path, default=default_bridge())
    parser.add_argument('--dry-run', action='store_true', help='Mostra il comando senza avviarlo.')
    args = parser.parse_args(argv)
    executable = shutil.which('tunnel-client')
    bridge = args.bridge.expanduser().resolve()
    if args.action == 'check':
        print('tunnel-client: ' + ('disponibile' if executable else 'da installare dal sito OpenAI'))
        print('bridge ftk-mcp: ' + ('disponibile' if bridge.is_file() and os.access(bridge, os.X_OK) else 'da compilare'))
        print('chiave runtime: ' + ('configurata in ambiente' if os.environ.get('CONTROL_PLANE_API_KEY') else 'non configurata in ambiente'))
        print('Account, tunnel e workspace: da verificare con doctor e ChatGPT; check è solo locale.')
        print('Guida: ' + DOCS)
        return 0
    try:
        cmd = command(args.action, executable or 'tunnel-client', bridge, args.tunnel_id)
    except ValueError as e:
        parser.error(str(e))
    if args.dry_run:
        print(shlex.join(cmd))
        return 0
    if not executable:
        parser.error('Installare il tunnel-client ufficiale: ' + DOCS)
    if not bridge.is_file() or not os.access(bridge, os.X_OK):
        parser.error('Bridge mancante. Installare FusionTakeoff.app o passare --bridge con il percorso copiato dal pannello Connettori.')
    if args.action in ['doctor', 'run'] and not os.environ.get('CONTROL_PLANE_API_KEY'):
        parser.error('Impostare CONTROL_PLANE_API_KEY nel terminale locale; non incollarla in chat.')
    # The tunnel client handles its own profile. No credentials passed on the command line.
    return subprocess.call(cmd)


if __name__ == '__main__':
    sys.exit(main())
