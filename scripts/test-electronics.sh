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
"$electronics_bin_dir/electronics-schematic" "$electronics_run_dir/schematic"
python3 Tests/Electronics/check_schematic.py "$electronics_run_dir/schematic"
"$electronics_bin_dir/electronics-pcb" "$electronics_run_dir/pcb"
python3 Tests/Electronics/check_pcb.py "$electronics_run_dir/pcb"
python3 Tests/Electronics/check_zones.py "$electronics_run_dir/pcb"
python3 Tests/Electronics/check_thermals.py "$electronics_run_dir/pcb"
"$electronics_bin_dir/electronics-fabrication" \
  Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/fabrication.json "$electronics_run_dir/fabrication"
python3 Tests/Electronics/check_fabrication.py "$electronics_run_dir/fabrication" \
  Packages/ElectronicsCore/Tests/ElectronicsCoreTests/Fixtures/fabrication.json "$electronics_bin_dir/electronics-fabrication"
printf 'Risultati elettronica: %s\n' "$electronics_run_dir"
