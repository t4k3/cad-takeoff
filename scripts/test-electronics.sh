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
electronics_bin_dir=$(swift build --package-path Packages/ElectronicsCore --show-bin-path)
python3 Tests/Electronics/check_library.py "$electronics_bin_dir/electronics-library" \
  Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures "$electronics_run_dir/library"
printf 'Risultati elettronica: %s\n' "$electronics_run_dir"
