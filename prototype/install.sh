#!/bin/bash
# 安裝 WhileAI 原型：編譯 → 複製到 ~/Applications → 在 Codex 與 Claude Code 加入 hooks → 啟動
# 不會動到 config.toml 的 notify（那個位置可能已被其他工具使用）。
set -euo pipefail
cd "$(dirname "$0")"

# 正式伺服器網址寫在 repo 根目錄的 whileai.json；空白時使用本機伺服器（只有自己能用）
SERVER=$(/usr/bin/python3 -c "import json;print(json.load(open('../whileai.json')).get('server','').strip())" 2>/dev/null || true)
WHILEAI_DEFAULT_SERVER="$SERVER" ./build.sh
DEST="$HOME/Applications/WhileAI.app"
mkdir -p "$HOME/Applications"
pkill -f "WhileAI.app/Contents/MacOS/WhileAI" 2>/dev/null || true
rm -rf "$DEST"
cp -R build/WhileAI.app "$DEST"

echo "加入 hooks："
/usr/bin/python3 hooks_config.py install "$DEST/Contents/MacOS/WhileAI"

# 開機（登入）時自動啟動；bootstrap 時也會立刻啟動一次
AGENT="$HOME/Library/LaunchAgents/ai.whileai.app.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.whileai.app</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/WhileAI</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/ai.whileai.app" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo
echo "完成。WhileAI 已啟動，之後登入 Mac 時也會自動啟動。"
echo "Claude Code 會自動套用新的 hooks。"
echo "Codex 規定新 hooks 必須先信任才會執行："
/usr/bin/python3 trust_hooks.py || echo "  （無法自動信任，請在 Codex CLI 輸入 /hooks）"
