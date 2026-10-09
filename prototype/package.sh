#!/bin/bash
# 打包給朋友的 WhileAI：./package.sh https://你的網址.up.railway.app
# 產生 dist/WhileAI.zip。朋友解壓縮、拖進「應用程式」、打開後，App 會自己連接 Codex 與 Claude Code。
set -euo pipefail
cd "$(dirname "$0")"

SERVER="${1:-}"
[[ "$SERVER" =~ ^https:// ]] || { echo "用法：./package.sh https://<正式伺服器網址>"; exit 1; }

WHILEAI_DEFAULT_SERVER="${SERVER%/}" ./build.sh
APP=build/WhileAI.app
cp hooks_config.py trust_hooks.py "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

rm -rf dist && mkdir -p dist/WhileAI
cp -R "$APP" dist/WhileAI/
cat > dist/WhileAI/安裝說明.txt <<TXT
WhileAI：等 AI Agent 的空檔，和朋友互相出題

1. 把 WhileAI 拖到「應用程式」資料夾。
2. 打開 WhileAI。macOS 會說「無法驗證開發者」，因為這是還沒經過 Apple 簽章的測試版：
   到「系統設定 → 隱私權與安全性」，往下找到 WhileAI，按「強制打開」。
   （或在終端機執行：xattr -dr com.apple.quarantine /Applications/WhileAI.app）
3. 按「連接」，讓 WhileAI 連上你的 Codex／Claude Code，然後取一個暱稱。
4. 點朋友給你的邀請連結，選「在 WhileAI App 中加入」。

之後在 Codex 或 Claude Code 工作超過幾秒時，右上角就會出現群組的題目。
答案完全匿名；WhileAI 不會讀取你的程式碼或 prompt。

伺服器：${SERVER%/}
需要：macOS 13 以上、Apple Silicon（M 系列晶片）
TXT
(cd dist && ditto -c -k --norsrc --noextattr --keepParent WhileAI WhileAI.zip && rm -rf WhileAI)
echo "完成：$(pwd)/dist/WhileAI.zip"
