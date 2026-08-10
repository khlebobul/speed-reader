#!/bin/bash
set -e

APP_NAME="Speed Reader"
SCHEME_NAME="SpeedReader"
BUILD_DIR="SpeedReader/.build/Build/Products/Release"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DIST_DIR="dist"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

if [ ! -d "${APP_BUNDLE}" ]; then
    error "App bundle not found at ${APP_BUNDLE}. Run 'make release' first."
fi

if ! command -v create-dmg &>/dev/null; then
    error "create-dmg not found. Install it with: npm install -g create-dmg"
fi

BINARY_PATH="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
if [ -f "${BINARY_PATH}" ]; then
    ARCHS=$(lipo -archs "${BINARY_PATH}" 2>/dev/null || echo "unknown")
    if [[ "$ARCHS" == *"x86_64"* ]] && [[ "$ARCHS" == *"arm64"* ]]; then
        info "Universal binary confirmed (${ARCHS})"
    else
        warn "Binary is NOT universal. Architectures found: ${ARCHS}"
    fi
fi

SIGNING_IDENTITY=""
NOTARY_PROFILE="SpeedReader"
NOTARIZE=false
NO_SIGN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --no-sign)
            NO_SIGN=true
            shift
            ;;
        --notary-profile)
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --notarize)
            NOTARIZE=true
            shift
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

ENTITLEMENTS="SpeedReader/SpeedReader/SpeedReader.entitlements"

if [ -z "${SIGNING_IDENTITY}" ] && [ "${NO_SIGN}" = false ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
        | head -1)
    [ -n "${SIGNING_IDENTITY}" ] || error "Developer ID Application certificate not found in Keychain"
fi

if [ -n "${SIGNING_IDENTITY}" ]; then
    info "Signing app bundle with: ${SIGNING_IDENTITY}"

    find "${APP_BUNDLE}/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) 2>/dev/null | while read -r lib; do
        codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${lib}"
    done

    codesign --deep --force --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${SIGNING_IDENTITY}" \
        "${APP_BUNDLE}"

    info "Verifying code signature..."
    codesign --verify --deep --strict "${APP_BUNDLE}"
    info "Code signature verified"
fi

mkdir -p "${DIST_DIR}"

info "Creating DMG with create-dmg..."

CREATE_DMG_ARGS=("--overwrite")

if [ -n "${SIGNING_IDENTITY}" ]; then
    CREATE_DMG_ARGS+=("--identity=${SIGNING_IDENTITY}")
elif [ "${NO_SIGN}" = true ]; then
    CREATE_DMG_ARGS+=("--no-code-sign")
fi

create-dmg "${CREATE_DMG_ARGS[@]}" "${APP_BUNDLE}" "${DIST_DIR}" || true

DMG_FILE=$(ls -t "${DIST_DIR}"/*.dmg 2>/dev/null | head -1)

if [ -z "${DMG_FILE}" ]; then
    error "DMG creation failed"
fi

STABLE_DMG="${DIST_DIR}/SpeedReader.dmg"
if [ "${DMG_FILE}" != "${STABLE_DMG}" ]; then
    mv -f "${DMG_FILE}" "${STABLE_DMG}"
    DMG_FILE="${STABLE_DMG}"
fi

if [ "${NOTARIZE}" = true ]; then
    info "Submitting DMG for notarization with Keychain profile: ${NOTARY_PROFILE}"
    xcrun notarytool submit "${DMG_FILE}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    info "Stapling notarization ticket..."
    xcrun stapler staple "${DMG_FILE}"

    info "Verifying notarization..."
    spctl --assess --type open --context context:primary-signature -v "${DMG_FILE}"
    info "Notarization verified"
fi

FINAL_SIZE=$(du -h "${DMG_FILE}" | cut -f1 | xargs)
info "Successfully created ${DMG_FILE} (${FINAL_SIZE})"
