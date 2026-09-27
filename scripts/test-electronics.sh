#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/ElectronicsCore
mkdir -p build/electronics
electronics_run_dir=$(mktemp -d "$PWD/build/electronics/run.XXXXXX")
swift run --package-path Packages/ElectronicsCore electronics-check \
  Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/assembly.json \
  "$electronics_run_dir/assembly"
python3 Tests/Electronics/check_assembly.py "$electronics_run_dir/assembly"
printf 'Risultati elettronica: %s\n' "$electronics_run_dir"
