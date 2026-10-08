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
swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build --package-path "${PROJECT_DIR}" -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
install -m 755 "${BIN_DIR}/Restly" "${CONTENTS_DIR}/MacOS/Restly"
install -m 644 "${PROJECT_DIR}/Support/Info.plist" "${CONTENTS_DIR}/Info.plist"
# 每次打包生成唯一构建号（git 短哈希 + 时间戳）：开发期间反复打体验包时，
# 版本徽标能区分新旧，避免「0.2.0 到底是不是新版」的困惑。发版时正式版本号仍由 Support/Info.plist 控制。
# CFBundleVersion 必须是纯数字（1–3 段句点分隔整数，Apple 文档要求）：
# 用「仓库提交总数.月日时分」——提交数单调递增、时间戳区分同提交重打包。
# git 短哈希放进独立诊断键 RestlyBuildStamp（黑匣子日志用于对齐 commit）。
COMMIT_COUNT="$(git -C "${PROJECT_DIR}" rev-list --count HEAD)"
BUILD_STAMP="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD)-$(date +%m%d%H%M)"
# CFBundleVersion 各段有位宽限制（主版本≤4位，次/补丁≤2位）：
# 用「提交数.月.日」——提交数主导单调性，同日重打包的差异由 RestlyBuildStamp 区分。
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${COMMIT_COUNT}.$(date +%-m).$(date +%-d)" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RestlyBuildStamp string ${BUILD_STAMP}" "${CONTENTS_DIR}/Info.plist"
install -m 644 "${ICON_SOURCE_PATH}" "${CONTENTS_DIR}/Resources/RestlyIcon.png"
install -m 644 "${PROJECT_DIR}/LICENSE" "${CONTENTS_DIR}/Resources/LICENSE"
ditto "${ASSET_OUTPUT_DIR}/" "${CONTENTS_DIR}/Resources/"

# 开源分发统一使用临时签名，不依赖构建机器上的个人开发证书。
codesign --force --deep --sign - "${APP_DIR}"
echo "已使用临时签名。"

echo "App 构建完成：${APP_DIR}"
zsh "${PROJECT_DIR}/scripts/create-dmg.sh"
cd "${PROJECT_DIR}/dist"
shasum -a 256 Restly.dmg > SHA256SUMS.txt
