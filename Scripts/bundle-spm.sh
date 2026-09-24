#!/bin/bash
#
# Assembles LocalBoard.app from the SwiftPM build, with no Xcode project.
#
# The Xcode app target and this script compile the same App/main.swift and read
# the same Config/AppInfo.xcconfig, so the two build paths cannot drift. Xcode
# expands the $(...) variables in Info.plist itself; here we do it by hand from
# the same file.
#
# Usage: Scripts/bundle-spm.sh [debug|release]   (default: release)

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCCONFIG="$ROOT/Config/AppInfo.xcconfig"
DIST="$ROOT/dist"

cd "$ROOT"

# Reads one key from the xcconfig. Values there are literal or one level of
# $(...) indirection; we only ever ask for the literal ones.
config() {
    local value
    value="$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$XCCONFIG" | head -1 | sed -E 's/^[^=]*=[[:space:]]*//' | sed -E 's/[[:space:]]*$//')"
    if [[ -z "$value" ]]; then
        echo "bundle-spm.sh: $1 is not set in Config/AppInfo.xcconfig" >&2
        exit 1
    fi
    printf '%s' "$value"
}

NAME="$(config APP_DISPLAY_NAME)"
BUNDLE_ID="$(config APP_BUNDLE_ID)"
VERSION="$(config MARKETING_VERSION)"
BUILD="$(config CURRENT_PROJECT_VERSION)"
DEPLOYMENT_TARGET="$(config MACOSX_DEPLOYMENT_TARGET)"

APP="$DIST/$NAME.app"
CONTENTS="$APP/Contents"

echo "==> Building LocalBoardApp ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product LocalBoardApp

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/LocalBoardApp"
if [[ ! -x "$BINARY" ]]; then
    echo "bundle-spm.sh: no executable at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $NAME.app"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# The SwiftPM product is LocalBoardApp; inside the bundle it must match
# CFBundleExecutable, which Xcode would set to PRODUCT_NAME.
cp "$BINARY" "$CONTENTS/MacOS/$NAME"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Same substitutions Xcode performs on the shared Info.plist.
sed -e "s/\$(EXECUTABLE_NAME)/$NAME/g" \
    -e "s/\$(PRODUCT_NAME)/$NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$DEPLOYMENT_TARGET/g" \
    "$ROOT/App/Info.plist" > "$CONTENTS/Info.plist"

plutil -lint "$CONTENTS/Info.plist" > /dev/null

# The asset catalog is a placeholder until real icon art lands, so a failure
# here is a missing icon, not a broken build.
if command -v actool > /dev/null 2>&1; then
    echo "==> Compiling asset catalog"
    if actool \
        --output-format human-readable-text \
        --compile "$CONTENTS/Resources" \
        --platform macosx \
        --minimum-deployment-target "$DEPLOYMENT_TARGET" \
        --target-device mac \
        --app-icon AppIcon \
        --accent-color AccentColor \
        --output-partial-info-plist "$(mktemp -t localboard-assets)" \
        "$ROOT/App/Assets.xcassets" > /dev/null 2>&1
    then
        echo "    Assets.car written"
    else
        echo "    skipped (no icon art yet)"
    fi
fi

# Ad-hoc signature. Real distribution needs a Developer ID, but the sandbox and
# hardened runtime are enforced locally with this, which is what we need to know
# works: ContainerPaths.detectHost() only sees a container when the sandbox is
# actually applied.
echo "==> Signing (ad-hoc)"
codesign --force --sign - \
    --entitlements "$ROOT/App/LocalBoard.entitlements" \
    --options runtime \
    --timestamp=none \
    "$APP"

codesign --verify --strict "$APP"

echo
echo "$APP"
