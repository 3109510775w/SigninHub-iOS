#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

SCHEME=SigninHub
CONFIG=Release
ARCHIVE=build/SigninHub.xcarchive
EXPORT=build/SigninHub-unsigned.ipa

# 前置检查
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[!] 缺少 XcodeGen，请先安装:  brew install xcodegen"
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "[!] 缺少 Xcode 工具链（需要 macOS + Xcode）"
  exit 1
fi

echo "[1/4] 生成 .xcodeproj ..."
xcodegen generate

echo "[2/4] Archive（无签名）..."
xcodebuild -project SigninHub.xcodeproj -scheme "$SCHEME" \
  -configuration "$CONFIG" -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  archive

echo "[3/4] 打包未签名 IPA ..."
APP="$ARCHIVE/Products/Applications/SigninHub.app"
rm -rf Payload
mkdir -p Payload
cp -R "$APP" Payload/
ditto -c -k --sequesterRsrc --keepParent Payload "$EXPORT"
rm -rf Payload

echo "[4/4] 完成: $EXPORT"
echo ""
echo "安装方式："
echo "  - 巨魔（仅 iOS 14.0-16.6.1 / 17.0）：直接把此 IPA 拖进 TrollStore 安装（永久签）"
echo "  - 自签（任意 iOS 版本）：用 AltStore / Sideloadly / 爱思助手 重新签名后安装"
echo "      * 免费 Apple ID 证书 7 天掉签，需续签"
echo "      * 付费开发者账号 \$99/年，1 年有效"
