# WhileAI 原型 v0.2：群組 × 互相出題（macOS）

群組成員可以互相出題。題目會在你等 Codex 超過幾秒時出現在右上角，點一下就答完；截止後，下一次等待時開獎。答案完全匿名。

```
Codex ──hooks──▶ WhileAI hook（只取事件名稱）──▶ WhileAI.app（選單列）──HTTP──▶ server/（API ＋ 網頁）
                                                                                   ▲
                                                           沒裝 App 的成員 ──網頁──┘
```

## 安裝

```bash
./install.sh
./trust_hooks.py
```

- **`install.sh`：** 編譯 App 並放進 `~/Applications`；在 `~/.codex/hooks.json` 加入 4 個 hooks；設定登入時自動啟動，並立刻啟動一次。
- **`trust_hooks.py`：** 透過 Codex 官方的 app-server 協定，信任 WhileAI 的 hooks，效果等同在 Codex CLI 輸入 `/hooks` 後按信任。只會動到 WhileAI 自己的 hooks。用 `--check` 可以只檢查狀態。
- **後端：** App 連不上本機伺服器時，會自動啟動內附的後端，資料庫是 `~/.whileai/server.db`，所以不用另外開伺服器。

第一次啟動時，小框框會請你設定暱稱。

### 支援哪些 Agent

| Agent | 自動跳出題目 | 設定檔 |
|---|---|---|
| Codex CLI | ✅ 已實測 | `~/.codex/hooks.json`，需要信任（`trust_hooks.py`） |
| Codex 桌面 App | 和 CLI 共用核心與設定，應該可以 | 同上 |
| Claude Code（終端機、IDE、Claude 桌面 App） | ✅ 模擬事件已測試 | `~/.claude/settings.json`，自動生效 |
| 雲端執行的 Agent（Codex 網頁版等） | ❌ 收不到事件；可以從選單列或網頁回答 | — |

Claude Code 按 Esc 中斷時不會送出 `Stop`，所以 session 超過 45 分鐘沒有事件就視為已結束。卡片會依正在跑的 Agent 顯示「Codex 工作中」或「Claude Code 工作中」。

想確認 Agent 有沒有送出事件，可以看 `~/.whileai/hooks.log`（只記時間和事件名稱）。

### 移除

```bash
./uninstall.sh
```

`uninstall.sh` 會移除 App、兩邊的 hooks 和開機啟動。加上 `--purge` 會連 `~/.whileai` 一起刪除。`config.toml` 裡的 `hooks.state` 信任紀錄會留著，但 hooks 移除後就不會再作用。

邀請連結目前是 `http://127.0.0.1:8787/j/<邀請碼>`，**只有你自己的電腦打得開**。要讓同事加入，後端必須先部署到公開網址。

## App 怎麼決定顯示什麼

| 時機 | 行為 |
|---|---|
| `UserPromptSubmit` | 先同步題目；任務超過 8 秒才顯示 |
| 選題順序 | ① 還沒看過的開獎 ② 群組待答題（已靜音的群組不會出現） |
| 每日上限 | 每天最多 5 道新題目，其餘留在選單列的「待答題」 |
| 略過 | 這次等待內不再出現，下次等待會再出現 |
| `PermissionRequest` | 立刻收起 |
| `Stop`／`Interrupt` | 所有 session 都結束 → 顯示「✓ Codex 完成了」後收起 |

## 小框框（面板）

點選單列的 ⏳，會在圖示下方展開一個小框框；點外面或按 Esc 收起。所有操作都在裡面完成：

| 畫面 | 內容 |
|---|---|
| 首頁 | 出題、待你回答、新開獎、我出的題、群組（建立／加入）、暫停 1 小時。還沒有群組時，只顯示「建立群組」和「我有邀請碼」兩個選項 |
| 群組 | 邀請碼與「複製邀請」、出題、靜音、題目列表 |
| 出題 | 發到哪個群組、情境範本、問題、選項；題型、匿名、開獎時機、截止時間收在一行摘要裡，點了才展開 |
| 題目 | 回答，或看結果；答完可以接「下一題」；出題者可以提前開獎或撤回 |
| 加入 | 「貼上邀請」會從整段邀請訊息或連結裡抓出邀請碼 |
| 設定 | 改暱稱、暫停、結束 WhileAI |

畫面元件（按鈕、輸入框、分段選擇、標籤、列表、結果長條）都定義在 `Views.swift` 的「設計元件」區，新畫面請沿用。

Agent 工作時自動跳出的卡片也用同一個框框，但不會搶走鍵盤焦點，你可以繼續在終端機打字。
使用者自己打開框框時，Agent 的事件不會把它關掉。右鍵點 ⏳ 可以結束 WhileAI。

原始碼分成四個檔案：`Core.swift`（資料與 API）、`Views.swift`（畫面）、`App.swift`（App 邏輯）、`main.swift`（入口、hook 模式、快照）。

## 隱私

- `WhileAI hook` 只讀 `hook_event_name` 和 `session_id`。prompt、程式碼、路徑一律不讀取。
- 匿名題：後端只回傳彙總結果，任何 API 都不會顯示誰選了什麼；回答不到 3 人不公開。文字題的回答不依時間排序。
- 具名題：出題者明確選擇後才會顯示回答者，卡片上會標示「具名」。
- 本機互動紀錄只記題型，不記回答內容。
- 畫圖題存的是筆畫座標（0–1000 的整數），不是圖片；匿名題的畫作和文字回答一樣不依時間排序。
- 從 App 開網頁時，網址帶的是 2 分鐘內有效的一次性碼，App 的 token 不會出現在網址上。
- 本機資料都在 `~/.whileai/`：`identity.json`（身分）、`state.json`（看過的開獎、今日顯示紀錄）、`events.jsonl`（互動紀錄，用來驗證 H1／H2）。

## 開發與測試

```bash
./build.sh
python3 ../server/test_api.py
python3 test_e2e.py
./build/WhileAI.app/Contents/MacOS/WhileAI snapshot /tmp
```

- `test_api.py`：後端 API 測試。
- `test_e2e.py`：真的啟動 App 和後端，用模擬的 hook 事件驅動。
- `snapshot <資料夾> [--dark]`：把小框框的每個畫面渲染成 PNG（淺色或深色），用來檢查排版。

開發時可以用的環境變數：`WHILEAI_SERVER`、`WHILEAI_DATA_DIR`、`WHILEAI_DELAY`、`WHILEAI_GAP`。

## 還沒做的

- **部署後端到公開網址。** 做完才能邀真正的同事。App 端只要在 `~/.whileai/config.json` 寫 `{"server": "https://…"}`。
- 範本題、修改或撤回題目、複製結果卡到 Slack、刪除我的資料（P1）。
- 跨群組比較、公開範本（P2）。
- 一個人同時用網頁和 App 加入，可能會變成兩個身分。從 App 開網頁（一次性碼）就不會有這個問題。
- 還沒在 Codex 桌面版（ChatGPT.app）驗證 hooks 會不會觸發。
