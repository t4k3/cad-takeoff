#!/usr/bin/env bash
# Regenerates the Xcode project from project.yml and builds the app (Debug).
# Exit status is xcodebuild's own: non-zero on BUILD FAILED.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
log="build/xcodebuild.log"
mkdir -p build
status=0
xcodebuild -project FusionTakeoff.xcodeproj -scheme FusionTakeoff -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData build >"$log" 2>&1 || status=$?
grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" "$log" || true
exit $status
