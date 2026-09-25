#!/usr/bin/env bash
# Regenerates the Xcode project from project.yml and builds the app (Debug).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project FusionTakeoff.xcodeproj -scheme FusionTakeoff -configuration Debug \
  -derivedDataPath build/DerivedData build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
