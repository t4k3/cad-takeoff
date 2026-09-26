#!/usr/bin/env bash
# Signed, notarized .dmg to give CAD Takeoff to someone outside the App Store / TestFlight.
#   scripts/make-dmg.sh   → build/dmg/CAD-Takeoff-<version>.dmg
# Uses Xcode's account (Xcode › Settings › Accounts, team 9F8D583GBV): cloud-managed Developer ID
# signing and Apple's notary service, so no local certificate or notarytool password is needed.
# The app inside is notarized and stapled, so it opens on any Mac without Gatekeeper warnings.
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/dmg
rm -rf "$out"; mkdir -p "$out"
build_number=$(date +%Y%m%d%H%M)

echo "1/4 Archivio Release (build $build_number)…"
xcodegen generate >/dev/null
xcodebuild -project FusionTakeoff.xcodeproj -scheme FusionTakeoff -configuration Release \
    -archivePath "$out/FusionTakeoff.xcarchive" -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CURRENT_PROJECT_VERSION="$build_number" \
    -allowProvisioningUpdates archive >"$out/archive.log" 2>&1 || { tail -20 "$out/archive.log"; exit 1; }

echo "2/4 Firma Developer ID e invio alla notarizzazione Apple…"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>9F8D583GBV</string>
    <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/FusionTakeoff.xcarchive" -exportPath "$out/submitted" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates >"$out/export.log" 2>&1 \
    || { tail -20 "$out/export.log"; exit 1; }

echo "3/4 Attendo l'esito (di solito pochi minuti)…"
for attempt in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$out/FusionTakeoff.xcarchive" -exportPath "$out/notarized" \
        >"$out/notarized.log" 2>&1; then
        break
    fi
    if grep -qiE "invalid|rejected" "$out/notarized.log"; then tail -20 "$out/notarized.log"; exit 1; fi
    [[ $attempt == 60 ]] && { echo "Notarizzazione non conclusa dopo 30 minuti."; tail -5 "$out/notarized.log"; exit 1; }
    sleep 30
done
app="$out/notarized/FusionTakeoff.app"
xcrun stapler validate "$app"
spctl -a -t exec -vv "$app"

echo "4/4 Immagine disco…"
stage="$out/stage"
mkdir -p "$stage"
ditto "$app" "$stage/CAD Takeoff.app"
ln -s /Applications "$stage/Applicazioni"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="$out/CAD-Takeoff-$version-$build_number.dmg"
hdiutil create -volname "CAD Takeoff" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"
echo "Pronto: $dmg ($(du -h "$dmg" | cut -f1))"
