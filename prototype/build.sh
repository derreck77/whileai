#!/bin/bash
# 編譯 WhileAI.app 到 prototype/build/
set -euo pipefail
cd "$(dirname "$0")"

APP=build/WhileAI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 依序嘗試：預設 SDK → Command Line Tools 裡的各版 SDK（新到舊）。
# 有些機器的預設 SDK 比 swiftc 新而無法編譯，換舊一點的 SDK 就可以。
compile() { swiftc -O ${@+"$@"} -target arm64-apple-macos13.0 -o "$APP/Contents/MacOS/WhileAI" Sources/*.swift; }
if ! compile 2>/dev/null; then
  ok=0; last=""
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -r); do
    last="$sdk"
    if compile -sdk "$sdk" 2>/dev/null; then ok=1; break; fi
  done
  # 全部失敗時，顯示最舊那個 SDK 的錯誤：它最不可能是「SDK 太新」，看到的才是程式碼本身的問題
  [ "$ok" = 1 ] || { echo "編譯失敗，以下是錯誤訊息："; compile ${last:+-sdk "$last"}; exit 1; }
fi

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
  <key>WhileAIInstallURL</key><string>__INSTALL_URL__</string>
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
/usr/bin/sed -i '' -e "s#__DEFAULT_SERVER__#${WHILEAI_DEFAULT_SERVER:-}#" \
  -e "s#__INSTALL_URL__#${WHILEAI_INSTALL_URL:-}#" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
