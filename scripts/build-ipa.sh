#!/usr/bin/env bash
set -euo pipefail

# Run from a Mac with Xcode. All output stays inside this project's build folder.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_DIR="$PROJECT_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
mkdir -p "$BUILD_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This build requires macOS and Xcode, or the included manual GitHub Actions workflow." >&2
    exit 1
fi

python3 "$PROJECT_ROOT/scripts/verify-source.py"
xcodebuild -version
plutil -lint "$PROJECT_ROOT/ComfyWorkbench/Info.plist" "$PROJECT_ROOT/ComfyWorkbench.xcodeproj/project.pbxproj"
# Use an already installed iPhone simulator; never download a runtime implicitly.
SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
phones = [(runtime, device) for runtime, devices in data["devices"].items() if ".iOS-" in runtime for device in devices if device["name"].startswith("iPhone") and device.get("isAvailable")]
assert phones, "No installed iPhone simulator is available"
runtime, device = sorted(phones, key=lambda entry: entry[0], reverse=True)[0]
print(device["udid"])
')"
xcodebuild \
    -project "$PROJECT_ROOT/ComfyWorkbench.xcodeproj" \
    -scheme ComfyWorkbench \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath "$BUILD_DIR/SimulatorData" \
    -resultBundlePath "$BUILD_DIR/NativeTests.xcresult" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    test | tee "$BUILD_DIR/xcodebuild.log"
xcodebuild \
    -project "$PROJECT_ROOT/ComfyWorkbench.xcodeproj" \
    -scheme ComfyWorkbench \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    IPHONEOS_DEPLOYMENT_TARGET=15.0 \
    build | tee -a "$BUILD_DIR/xcodebuild.log"

SOURCE_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/ComfyWorkbench.app"
test -d "$SOURCE_APP"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/ipa.XXXXXX")"
mkdir -p "$STAGING_DIR/Payload"
ditto "$SOURCE_APP" "$STAGING_DIR/Payload/ComfyWorkbench.app"
APP="$STAGING_DIR/Payload/ComfyWorkbench.app"

# Sign any embedded code before the app. No Apple account or private entitlement is used.
if [[ -d "$APP/Frameworks" ]]; then
    while IFS= read -r -d '' embedded; do
        codesign --force --sign - --timestamp=none "$embedded"
    done < <(find "$APP/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
fi
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun lipo "$APP/ComfyWorkbench" -verify_arch arm64
xcrun vtool -show-build "$APP/ComfyWorkbench" | tee "$BUILD_DIR/macho-build-info.txt"
python3 - "$APP/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as file:
    info = plistlib.load(file)
assert info["MinimumOSVersion"] == "15.0", info.get("MinimumOSVersion")
assert info["CFBundleExecutable"] == "ComfyWorkbench"
assert info["UIDeviceFamily"] == [1], info.get("UIDeviceFamily")
print("Verified: iOS 15.0 minimum, iPhone application.")
PY

IPA="$BUILD_DIR/ComfyWorkbench.ipa"
ditto -c -k --keepParent "$STAGING_DIR/Payload" "$IPA"
python3 - "$IPA" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    assert "Payload/ComfyWorkbench.app/Info.plist" in names
    assert "Payload/ComfyWorkbench.app/ComfyWorkbench" in names
    assert not archive.testzip(), "IPA archive checksum failure"
print("IPA archive verified.")
PY
shasum -a 256 "$IPA" | tee "$BUILD_DIR/ComfyWorkbench.ipa.sha256"
echo "Built: $IPA"
