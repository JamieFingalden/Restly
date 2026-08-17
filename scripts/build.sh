#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${PROJECT_DIR}/dist/Restly.app"
CONTENTS_DIR="${APP_DIR}/Contents"
ICONSET_DIR="${PROJECT_DIR}/.build/Restly.iconset"
ICON_SOURCE_PATH="${PROJECT_DIR}/Support/RestlyIcon-v2.png"
ASSET_CATALOG_DIR="${PROJECT_DIR}/.build/RestlyAssets.xcassets"
ASSET_ICONSET_DIR="${ASSET_CATALOG_DIR}/AppIcon.appiconset"
ASSET_OUTPUT_DIR="${PROJECT_DIR}/.build/RestlyAssetOutput"
ASSET_INFO_PATH="${PROJECT_DIR}/.build/RestlyAssetInfo.plist"

echo "正在构建 Restly Release 版本…"
swift "${PROJECT_DIR}/scripts/generate-icon.swift" "${ICON_SOURCE_PATH}" "${ICONSET_DIR}"
rm -rf "${ASSET_CATALOG_DIR}" "${ASSET_OUTPUT_DIR}"
mkdir -p "${ASSET_ICONSET_DIR}" "${ASSET_OUTPUT_DIR}"
ditto "${ICONSET_DIR}" "${ASSET_ICONSET_DIR}"
install -m 644 \
    "${PROJECT_DIR}/Support/Assets.xcassets/AppIcon.appiconset/Contents.json" \
    "${ASSET_ICONSET_DIR}/Contents.json"
xcrun actool "${ASSET_CATALOG_DIR}" \
    --compile "${ASSET_OUTPUT_DIR}" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${ASSET_INFO_PATH}" \
    --warnings \
    --notices
swift build --package-path "${PROJECT_DIR}" -c release
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" -c release --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
install -m 755 "${BIN_DIR}/Restly" "${CONTENTS_DIR}/MacOS/Restly"
install -m 644 "${PROJECT_DIR}/Support/Info.plist" "${CONTENTS_DIR}/Info.plist"
install -m 644 "${ICON_SOURCE_PATH}" "${CONTENTS_DIR}/Resources/RestlyIcon.png"
ditto "${ASSET_OUTPUT_DIR}/" "${CONTENTS_DIR}/Resources/"

SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -n 1
)"
if [[ -n "${SIGNING_IDENTITY}" ]]; then
    codesign --force --deep --options runtime --timestamp=none --sign "${SIGNING_IDENTITY}" "${APP_DIR}"
    echo "已使用 Apple Development 签名：${SIGNING_IDENTITY}"
else
    codesign --force --deep --sign - "${APP_DIR}"
    echo "未找到 Apple Development 证书，已使用临时签名。"
fi

echo "App 构建完成：${APP_DIR}"
zsh "${PROJECT_DIR}/scripts/create-dmg.sh"
