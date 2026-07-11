#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Agent Inbox"
PRODUCT_NAME="agent-inbox"
ARCHIVE_BASENAME="${AGENT_INBOX_ARCHIVE_BASENAME:-Agent.Inbox}"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
ICON_SOURCE="${ROOT_DIR}/Assets/AppIcon/agent-inbox-icon.png"
ICON_NAME="AgentInbox.icns"
ICON_PATH="${RESOURCES_DIR}/${ICON_NAME}"

VERSION="${AGENT_INBOX_VERSION:-0.0.1}"
BUILD_NUMBER="${AGENT_INBOX_BUILD:-$(date -u +%Y%m%d%H%M%S)}"
BUNDLE_ID="${AGENT_INBOX_BUNDLE_ID:-engineering.super.agent-inbox}"
FEED_URL="${AGENT_INBOX_UPDATE_FEED_URL:-}"
PUBLIC_ED_KEY="${AGENT_INBOX_SPARKLE_PUBLIC_KEY:-}"
SIGN_IDENTITY="${AGENT_INBOX_SIGN_IDENTITY:-}"
ARCHS="${AGENT_INBOX_ARCHS:-arm64 x86_64}"

log() {
    printf '[package_app] %s\n' "$*"
}

if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    log "invalid build number '${BUILD_NUMBER}': CFBundleVersion must contain only digits and dots"
    exit 1
fi

swift_build_args=(
    -c release
    --product "${PRODUCT_NAME}"
    -Xswiftc -strict-concurrency=complete
    -Xswiftc -warn-concurrency
    -Xswiftc -warnings-as-errors
)
for arch in ${ARCHS}; do
    swift_build_args+=(--arch "${arch}")
done

log "building ${PRODUCT_NAME} ${VERSION} (${BUILD_NUMBER}) for ${ARCHS}"
swift build "${swift_build_args[@]}"

binary_path="${ROOT_DIR}/.build/apple/Products/Release/${PRODUCT_NAME}"
if [[ ! -x "${binary_path}" ]]; then
    binary_path="$(find "${ROOT_DIR}/.build" -type f -name "${PRODUCT_NAME}" -path '*/[Rr]elease/*' -perm +111 | sort | tail -n 1)"
fi
if [[ -z "${binary_path}" ]]; then
    log "release binary not found"
    exit 1
fi

log "creating app bundle at ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"
cp "${binary_path}" "${MACOS_DIR}/${PRODUCT_NAME}"

if [[ ! -f "${ICON_SOURCE}" ]]; then
    log "app icon source not found: ${ICON_SOURCE}"
    exit 1
fi

log "generating app icon ${ICON_NAME}"
iconset_parent="$(mktemp -d "${TMPDIR:-/tmp}/agent-inbox-icon.XXXXXX")"
iconset_dir="${iconset_parent}/AgentInbox.iconset"
mkdir -p "${iconset_dir}"
trap 'rm -rf "${iconset_parent}"' EXIT

# macOS bundles need an .icns resource plus CFBundleIconFile; a loose PNG is ignored by Finder.
declare -a icon_variants=(
    "16 icon_16x16.png"
    "32 icon_16x16@2x.png"
    "32 icon_32x32.png"
    "64 icon_32x32@2x.png"
    "128 icon_128x128.png"
    "256 icon_128x128@2x.png"
    "256 icon_256x256.png"
    "512 icon_256x256@2x.png"
    "512 icon_512x512.png"
    "1024 icon_512x512@2x.png"
)

for variant in "${icon_variants[@]}"; do
    read -r size filename <<< "${variant}"
    sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${iconset_dir}/${filename}" >/dev/null
done

iconutil -c icns "${iconset_dir}" -o "${ICON_PATH}"

sparkle_framework="$(find "${ROOT_DIR}/.build" -type d -path '*Sparkle.xcframework/macos*/Sparkle.framework' | sort | head -n 1)"
if [[ -z "${sparkle_framework}" ]]; then
    log "Sparkle.framework not found"
    exit 1
fi

log "embedding Sparkle.framework"
cp -R "${sparkle_framework}" "${FRAMEWORKS_DIR}/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${PRODUCT_NAME}" 2>/dev/null || true

log "writing Info.plist"
plutil -create xml1 "${INFO_PLIST}"
plutil -insert CFBundleDevelopmentRegion -string "en" "${INFO_PLIST}"
plutil -insert CFBundleExecutable -string "${PRODUCT_NAME}" "${INFO_PLIST}"
plutil -insert CFBundleIdentifier -string "${BUNDLE_ID}" "${INFO_PLIST}"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "${INFO_PLIST}"
plutil -insert CFBundleName -string "${APP_NAME}" "${INFO_PLIST}"
plutil -insert CFBundleDisplayName -string "${APP_NAME}" "${INFO_PLIST}"
plutil -insert CFBundleIconFile -string "${ICON_NAME}" "${INFO_PLIST}"
plutil -insert CFBundlePackageType -string "APPL" "${INFO_PLIST}"
plutil -insert CFBundleShortVersionString -string "${VERSION}" "${INFO_PLIST}"
plutil -insert CFBundleVersion -string "${BUILD_NUMBER}" "${INFO_PLIST}"
plutil -insert LSMinimumSystemVersion -string "14.0" "${INFO_PLIST}"
plutil -insert LSUIElement -bool true "${INFO_PLIST}"
plutil -insert NSHighResolutionCapable -bool true "${INFO_PLIST}"

if [[ -n "${FEED_URL}" && -n "${PUBLIC_ED_KEY}" ]]; then
    log "enabling Sparkle feed ${FEED_URL}"
    plutil -insert SUFeedURL -string "${FEED_URL}" "${INFO_PLIST}"
    plutil -insert SUPublicEDKey -string "${PUBLIC_ED_KEY}" "${INFO_PLIST}"
    plutil -insert SUEnableAutomaticChecks -bool true "${INFO_PLIST}"
    plutil -insert SUScheduledCheckInterval -integer 86400 "${INFO_PLIST}"
else
    log "Sparkle disabled for this bundle: feed URL or public key missing"
fi

log "signing app bundle"
if [[ -n "${SIGN_IDENTITY}" ]]; then
    codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}"
else
    codesign --force --deep --sign - "${APP_DIR}"
fi

ZIP_PATH="${DIST_DIR}/${ARCHIVE_BASENAME}-${VERSION}-${BUILD_NUMBER}.zip"
rm -f "${ZIP_PATH}"
log "creating update archive ${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_PATH}"

log "done"
printf '%s\n' "${ZIP_PATH}"
