#!/bin/bash
# 編譯 WhileAI.app 到 prototype/build/
set -euo pipefail
cd "$(dirname "$0")"

APP=build/WhileAI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Command Line Tools 的預設 SDK 可能比 swiftc 新而無法編譯；有 26.5 SDK 時優先使用。
SDK_ARGS=()
CLT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -z "${SDKROOT:-}" ] && [ -d "$CLT_SDK" ] && SDK_ARGS=(-sdk "$CLT_SDK")

swiftc -O ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/WhileAI" Sources/main.swift

# 內附後端：App 連不上本機伺服器時會自己啟動它
mkdir -p "$APP/Contents/Resources/server"
cp ../server/server.py "$APP/Contents/Resources/server/"
cp -R ../server/web "$APP/Contents/Resources/server/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ai.whileai.prototype</string>
  <key>CFBundleName</key><string>WhileAI</string>
  <key>CFBundleExecutable</key><string>WhileAI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>WhileAIDefaultServer</key><string>__DEFAULT_SERVER__</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>ai.whileai.join</string>
      <key>CFBundleURLSchemes</key><array><string>whileai</string></array>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# 打包給朋友時，用 WHILEAI_DEFAULT_SERVER 指定正式伺服器網址（沒指定時為空 → 使用本機伺服器）
/usr/bin/sed -i '' "s#__DEFAULT_SERVER__#${WHILEAI_DEFAULT_SERVER:-}#" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
