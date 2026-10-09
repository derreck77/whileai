# WhileAI

**等 AI Agent 工作的空檔，和朋友互相出題。**

你在 Codex 或 Claude Code 交辦任務後，常常要等它跑一陣子。WhileAI 會在這段空檔，在右上角送出一張小卡片，題目是你群組裡的朋友出的。點一下就答完，大家都答了就開獎。

- **答案完全匿名：** 至少 3 人回答才公開結果，而且沒有人能看到誰選了什麼。
- **不打擾工作：** 任務超過 8 秒才出現；Agent 需要你時立刻收起；隨時可以略過或暫停。
- **不讀你的工作內容：** WhileAI 只接收「Agent 開始／完成」的事件，不會讀取你的程式碼、prompt 或專案。

## 開始使用

需要：Apple Silicon（M 系列晶片）的 Mac、macOS 13 以上，以及 Codex 或 Claude Code。

```bash
git clone https://github.com/derreck77/whileai.git
cd whileai
./setup.sh
```

1. `setup.sh` 會檢查環境、編譯 App，並連接你的 Codex 和 Claude Code，第一次約需 1 分鐘。如果還沒裝 Xcode Command Line Tools，它會先跳出安裝視窗。
2. 選單列右上角出現 ⏳ 後，取一個暱稱。
3. 點朋友給你的**邀請連結**，選「在 WhileAI App 中加入」。

完成。之後只要 Codex 或 Claude Code 在工作，題目就會自己出現。

## 怎麼玩

| 想做的事 | 在哪裡 |
|---|---|
| 回答題目 | 等 Agent 時右上角的卡片；或選單列 ⏳ →「待答題」 |
| 出題 | 選單列 ⏳ →「我的群組」→ 選群組 →「出題／看結果…」 |
| 建立群組、邀請朋友 | 選單列 ⏳ →「我的群組」→「建立新群組…」，再複製邀請連結傳給朋友 |
| 暫時不想被打擾 | 選單列 ⏳ →「暫停 1 小時」，或把某個群組設為靜音 |

沒裝 App 的朋友，也可以直接打開邀請連結，在網頁上回答。

## 支援的 Agent

| Agent | 題目會自動出現嗎 |
|---|---|
| Codex（CLI、桌面 App） | ✅ |
| Claude Code（終端機、IDE、Claude 桌面 App） | ✅ |
| 在雲端執行的 Agent（例如 Codex 網頁版） | ❌ 可以從選單列或網頁回答 |

## 移除

```bash
./prototype/uninstall.sh
```

這會移除 App、Codex 與 Claude Code 裡的 WhileAI 設定，以及開機自動啟動。加上 `--purge` 會連本機資料一起刪除。

## 專案結構

| 路徑 | 內容 |
|---|---|
| `setup.sh` | 一鍵安裝 |
| `whileai.json` | 正式伺服器網址 |
| `prototype/` | macOS 選單列 App（Swift）、安裝與移除腳本，見 [prototype/README.md](prototype/README.md) |
| `server/` | 後端 API 與網頁（Python 標準函式庫 ＋ SQLite） |
| `Dockerfile`、`railway.json` | 部署到 Railway 的設定 |
| `docs/` | 競品調查、User Stories |

這是原型階段的專案，歡迎回報問題或建議。
