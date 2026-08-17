#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="${PROJECT_DIR}/dist/Restly.app"
DMG_PATH="${PROJECT_DIR}/dist/Restly.dmg"

if [[ ! -d "${APP_DIR}" ]]; then
    echo "未找到 Restly.app，请先运行 scripts/build.sh。" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d /tmp/restly-dmg.XXXXXX)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

ditto "${APP_DIR}" "${STAGING_DIR}/Restly.app"
ln -s /Applications "${STAGING_DIR}/Applications"
rm -f "${DMG_PATH}"

echo "正在创建 Restly.dmg…"
hdiutil create \
    -volname "Restly" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

echo "DMG 创建完成：${DMG_PATH}"
