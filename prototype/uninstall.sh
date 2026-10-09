#!/bin/bash
# 移除 WhileAI：關閉 App、刪除 ~/Applications/WhileAI.app、從 Codex 與 Claude Code 的設定移除 WhileAI 的 hooks。
# 互動紀錄 ~/.whileai 會保留；要一併刪除請加上 --purge。
set -euo pipefail

launchctl bootout "gui/$(id -u)/ai.whileai.app" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/ai.whileai.app.plist"
pkill -f "WhileAI.app/Contents/MacOS/WhileAI" 2>/dev/null || true
rm -rf "$HOME/Applications/WhileAI.app"

/usr/bin/python3 "$(dirname "$0")/hooks_config.py" uninstall

[ "${1:-}" = "--purge" ] && rm -rf "$HOME/.whileai" && echo "Removed ~/.whileai"
echo "WhileAI 已移除。"
