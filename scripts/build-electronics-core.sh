#!/bin/bash
# ElectronicsCore as a dylib for the app's swiftc test runners: its C part (the ZIP inflater on
# the system libz) compiled first, with a module map beside the library so `-I <dir>` finds both.
# Usage: scripts/build-electronics-core.sh <output dir>
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1
c_dir=Packages/ElectronicsCore/Sources/CElectronicsArchive
cat > "$out/module.modulemap" <<MAP
module CElectronicsArchive {
    header "$PWD/$c_dir/include/CElectronicsArchive.h"
    export *
}
MAP
xcrun clang -c -O2 -I "$c_dir/include" "$c_dir/archive.c" -o "$out/CElectronicsArchive.o"
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find Packages/ElectronicsCore/Sources/ElectronicsCore -type f -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -emit-library -emit-module -module-name ElectronicsCore "${sources[@]}" \
    -I "$out" "$out/CElectronicsArchive.o" -lz \
    -emit-module-path "$out/ElectronicsCore.swiftmodule" -o "$out/libElectronicsCore.dylib"
