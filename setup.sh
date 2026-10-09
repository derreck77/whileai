#!/bin/bash
# WhileAI 一鍵安裝：./setup.sh
# 檢查環境 → 編譯 App → 連接 Codex 與 Claude Code → 設定登入時自動啟動
set -euo pipefail
cd "$(dirname "$0")"

say() { printf "\n\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\n❌ %s\n" "$1"; exit 1; }

say "1/3 檢查環境"
[ "$(uname)" = "Darwin" ] || fail "WhileAI 目前只支援 macOS。"
[ "$(uname -m)" = "arm64" ] || fail "WhileAI 目前只支援 Apple Silicon（M 系列晶片）的 Mac。"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || fail "需要 macOS 13 以上（目前是 $(sw_vers -productVersion)）。"
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null; then
  xcode-select --install 2>/dev/null || true
  fail "需要先安裝 Xcode Command Line Tools。已經跳出安裝視窗，裝好後再執行一次 ./setup.sh"
fi
echo "  ✓ macOS $(sw_vers -productVersion)、Apple Silicon、Command Line Tools"

SERVER=$(/usr/bin/python3 -c "import json;print(json.load(open('whileai.json')).get('server','').strip())")
if [ -n "$SERVER" ]; then
  echo "  ✓ 伺服器：$SERVER"
else
  echo "  ⚠︎ whileai.json 沒有設定伺服器，將使用本機伺服器（只有你自己能用，無法和朋友一起玩）"
fi

found=""
[ -d "$HOME/.codex" ] && found="Codex"
[ -d "$HOME/.claude" ] && found="${found:+$found、}Claude Code"
[ -n "$found" ] && echo "  ✓ 偵測到：$found" || echo "  ⚠︎ 沒有偵測到 Codex 或 Claude Code；裝好它們之後再執行一次 ./setup.sh"

say "2/3 編譯並安裝 WhileAI（第一次約需 1 分鐘）"
./prototype/install.sh

say "3/3 完成 🎉"
cat <<TXT
  • 選單列右上角會出現 ⏳，第一次會請你取一個暱稱
  • 點朋友給你的邀請連結，選「在 WhileAI App 中加入」
  • 之後 Codex 或 Claude Code 工作超過幾秒，右上角就會出現群組的題目

  移除：./prototype/uninstall.sh
TXT
