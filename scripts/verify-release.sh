#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${PROJECT_DIR}/dist/Restly.app"
INFO_PATH="${APP_DIR}/Contents/Info.plist"
BINARY_PATH="${APP_DIR}/Contents/MacOS/Restly"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PATH}")"

if [[ -n "${RESTLY_RELEASE_TAG:-}" && "${RESTLY_RELEASE_TAG}" != "v${VERSION}" ]]; then
    echo "发布标签 ${RESTLY_RELEASE_TAG} 与应用版本 v${VERSION} 不一致。" >&2
    exit 1
fi

echo "正在校验 Restly ${VERSION} 通用安装包…"
plutil -lint "${INFO_PATH}"
# 打包时 build.sh 会把包内 CFBundleVersion 改写为唯一构建号（git短哈希-时间戳），
# 这是有意为之的差异：断言戳记形态正确，其余所有键转成 XML 后仍要求完全一致。
STAMPED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PATH}")"
[[ "${STAMPED_BUILD}" =~ ^[0-9]{1,4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || {
    echo "包内 CFBundleVersion 不是合法的数字构建号（提交数.月日时分）：${STAMPED_BUILD}" >&2
    exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :RestlyBuildStamp' "${INFO_PATH}")" =~ ^[0-9a-f]{7,40}-[0-9]{8}$ ]] || {
    echo "包内缺少 RestlyBuildStamp 诊断键。" >&2
    exit 1
}
PLIST_CMP_DIR="$(mktemp -d /tmp/restly-plist.XXXXXX)"
plutil -convert xml1 -o "${PLIST_CMP_DIR}/support.xml" "${PROJECT_DIR}/Support/Info.plist"
plutil -convert xml1 -o "${PLIST_CMP_DIR}/packaged.xml" "${INFO_PATH}"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleVersion' "${PLIST_CMP_DIR}/support.xml"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleVersion' "${PLIST_CMP_DIR}/packaged.xml"
/usr/libexec/PlistBuddy -c 'Delete :RestlyBuildStamp' "${PLIST_CMP_DIR}/packaged.xml"
cmp "${PLIST_CMP_DIR}/support.xml" "${PLIST_CMP_DIR}/packaged.xml"
rm -rf "${PLIST_CMP_DIR}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PATH}")" == "13.0" ]]
[[ -x "${BINARY_PATH}" ]]
for BINARY_ARCH in arm64 x86_64; do
    lipo "${BINARY_PATH}" -verify_arch "${BINARY_ARCH}"
done
xcrun vtool -show-build "${BINARY_PATH}" | awk '
    /minos/ { if ($2 != "13.0") exit 1; count++ }
    END { if (count != 2) exit 1 }
'
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
[[ -s "${APP_DIR}/Contents/Resources/AppIcon.icns" ]]
[[ -s "${APP_DIR}/Contents/Resources/Assets.car" ]]
[[ -s "${APP_DIR}/Contents/Resources/RestlyIcon.png" ]]
cmp "${PROJECT_DIR}/LICENSE" "${APP_DIR}/Contents/Resources/LICENSE"

cd "${PROJECT_DIR}/dist"
shasum -a 256 -c SHA256SUMS.txt
hdiutil verify Restly.dmg

# 挂载最终 DMG，确保安装入口及包内应用与已校验的构建产物一致。
MOUNT_DIR="$(mktemp -d /tmp/restly-verify.XXXXXX)"
trap 'hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true; rmdir "${MOUNT_DIR}"' EXIT
hdiutil attach Restly.dmg -readonly -nobrowse -mountpoint "${MOUNT_DIR}"
[[ "$(readlink "${MOUNT_DIR}/Applications")" == "/Applications" ]]
cmp "${BINARY_PATH}" "${MOUNT_DIR}/Restly.app/Contents/MacOS/Restly"
cmp "${INFO_PATH}" "${MOUNT_DIR}/Restly.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "${MOUNT_DIR}/Restly.app"

echo "安装包校验通过：版本、双架构、最低系统版本、签名、资源、校验和及 DMG 安装入口均正确。"
