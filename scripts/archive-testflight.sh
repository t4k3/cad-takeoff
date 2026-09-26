#!/usr/bin/env bash
# Archive the app for TestFlight / App Store Connect.
#   scripts/archive-testflight.sh            → build/testflight/FusionTakeoff.pkg (upload it with Transporter)
#   scripts/archive-testflight.sh --upload   → also uploads to App Store Connect (Xcode account required)
# Needs: the app record in App Store Connect (bundle id com.takeoff.fusiontakeoff) and an Apple
# Distribution identity for team 9F8D583GBV (Xcode › Settings › Accounts). See docs/TESTFLIGHT.md.
set -euo pipefail
cd "$(dirname "$0")/.."
destination=export
[[ "${1:-}" == "--upload" ]] && destination=upload
out=build/testflight
rm -rf "$out"; mkdir -p "$out"
build_number=$(date +%Y%m%d%H%M)
xcodegen generate >/dev/null
xcodebuild -project FusionTakeoff.xcodeproj -scheme FusionTakeoff -configuration Release \
    -archivePath "$out/FusionTakeoff.xcarchive" -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CURRENT_PROJECT_VERSION="$build_number" \
    -allowProvisioningUpdates archive | tail -5
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$destination</string>
    <key>teamID</key><string>9F8D583GBV</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/FusionTakeoff.xcarchive" -exportPath "$out" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates | tail -5
echo "Build $build_number → $out ($destination)"
