#!/usr/bin/env bash
# 构建无沙箱版本：直读直写 ~/.zcode，自动重启 ZCode + 多开实例。
# 完整 Developer ID 分发流程：构建 → 签名 → 公证(Notarization) → 装订 → 打包。
#
# ── 一次性准备(每台机器只做一次)──────────────────────────────
# 1. 创建证书:Xcode → Settings → Accounts → 选中 Apple ID
#      → Manage Certificates… → 左下 + → Developer ID Application
#   (证书自动进钥匙串;名字形如 "Developer ID Application: 张三 (ABCDE12345)")
# 2. 生成 App 专用密码:https://appleid.apple.com → 登录与安全
#      → App 专用密码 → 生成,记下来(格式 xxxx-xxxx-xxxx-xxxx)
# 3. 存公证凭据(按提示再输一次 App 专用密码):
#      xcrun notarytool store-credentials ZCODE_NOTARY \
#        --apple-id 你的AppleID邮箱 \
#        --team-id 你的TeamID \
#        --password App专用密码
#   TeamID 查看处:developer.apple.com → Membership 详情页,
#   或 Xcode → Settings → Accounts → 点团队右侧 Team ID。
#
# ── 用法 ─────────────────────────────────────────────────────
#   scripts/build_dev.sh 'Developer ID Application: 你的名字 (TEAMID)'
#   不带参数 = 仅本机构建(本地签名,不分发)。
#   公证凭据档名可用环境变量覆盖:NOTARY_PROFILE=xxx scripts/build_dev.sh ...
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ZCODE_NOTARY}"

flutter build macos --release
APP="build/macos/Build/Products/Release/zcode_helper.app"

if [ -z "$IDENTITY" ]; then
  echo "⚠️  未提供签名身份，仅做本机运行构建（未签名/本地签名）。"
  echo "   分发构建: scripts/build_dev.sh 'Developer ID Application: 你的身份'"
  echo "产物: $APP"
  exit 0
fi

echo "── 1/5 签名(Hardened Runtime + entitlements)──"
codesign --force --deep --options runtime \
  --entitlements macos/Runner/Release.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "── 2/5 打待公证 zip ──"
UPLOAD="build/macos/notary-upload.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPLOAD"

echo "── 3/5 公证(上传 Apple 审核,通常 1~5 分钟)──"
xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$UPLOAD"

echo "── 4/5 装订公证票据(离线可验证)──"
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"

echo "── 5/5 打分发包 ──"
OUT="zcode_helper-macos-$(date +%Y%m%d-%H%M).zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
echo "✅ 完成:$OUT(已签名+公证+装订,可直接分发)"
