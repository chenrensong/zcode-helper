#!/usr/bin/env bash
# 构建无沙箱版本：直读直写 ~/.zcode，自动重启 ZCode + 多开实例。
# 用法：scripts/build_dev.sh [--codesign-identity 'Developer ID Application: xxx']
#   未提供签名身份时仅做本机构建（本地签名）。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-}"
flutter build macos --release

if [ -n "$IDENTITY" ]; then
  APP="build/macos/Build/Products/Release/zcode_helper.app"
  codesign --force --options runtime --deep --sign "$IDENTITY" "$APP"
  echo "✅ Developer ID 签名完成：$APP"
else
  echo "⚠️  未提供签名身份，仅做本机运行构建（未签名/本地签名）。"
  echo "   使用: scripts/build_dev.sh 'Developer ID Application: 你的身份'"
fi
echo "产物: build/macos/Build/Products/Release/zcode_helper.app"
