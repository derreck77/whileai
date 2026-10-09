# WhileAI 競品掃描（2026-10-09）

> 資料來源都是各家官網、GitHub 與第三方文章，收益與流量數字全是**廠商自報、未經驗證**。

## 結論先講

1. **「等待時顯示廣告、分潤給工程師」已經是擁擠的紅海。** 至少 10 家在做幾乎一樣的東西：把 spinner／status line 換成一行贊助文字，分 50–75% 給開發者。差異只剩支援哪些工具和分潤比例。
2. **錢很少。** 開發者端自報收入大約每月 US$1.6–8；Kickbacks 估每人每年約 US$75。adline 的廣告價格換算約 US$2–3 CPM，WaitSpin 範例是 €5 CPM。以「賺零用錢」當誘因很弱，跟策略文件的判斷一致。
3. **隱私已經成為攻擊點。** AdGuard 專文批評 Kickbacks 的 Boosted Mode 會把對話內容送上伺服器做廣告定向。這正好讓「隱私是產品特性」成為 WhileAI 能拿來說的差異。
4. **沒有人做「同儕投票＋即時看結果」（Developer Pulse）。** 我們搜尋到的產品，不是廣告就是小遊戲。**WhileAI 的切入點應該從 Pulse 開始，而不是 Discovery／贊助卡片。**

## 直接競品：等待廣告

| 產品 | 版位 | 支援工具 | 廣告主價格 | 開發者分潤 | 備註 |
|---|---|---|---|---|---|
| [adline](https://adline.dev/) | 改寫 Claude Code status line／spinner 文字 | Claude Code、Codex CLI | 月費 $29／1 萬曝光、$79／3 萬、$199／10 萬 | 50%，滿 $10 用 Stripe 付 | 自報 Ramp、Linear、Vercel 等檔期（未驗證） |
| [Kickbacks.ai](https://toknow.ai/posts/kickbacks-ai-get-paid-claude-code-spinner-ads/) | 取代「Thinking…」動詞，60 字元內 | VS Code 系編輯器裡的 Claude Code、Codex | — | 「約 50% 淨收入」，條款可隨時改 | 2026-06 上線；AdGuard 批評隱私（[文章](https://adguard.com/en/blog/ai-coding-ads-kickbacks-vscode.html)） |
| [WaitSpin](https://waitspin.com/) | 一行贊助文字，曝光 ≥5 秒才計費 | VS Code、Cursor、Claude Code、Copilot CLI、OpenCode 等 10 種 | 預付 CPM 制，範例 €5 | 60% | 標榜不傳程式碼／prompt；市場頁的 CPM 欄位仍是空的 |
| [AgenticAds](https://agenticads.dev/)、[IdleAds](https://idleads.dev/)、[spinyield](https://spinyield.com/)、[codewithads](https://codewithads.com/)、[Claude Code Ads](https://www.claudecodeads.com/)、[AdsInAgents](https://adsinagents.com/)、[Adviverse](https://adviverse.com/developer-ads) | 大同小異：status line／spinner 贊助文字 | 以 Claude Code 為主 | — | 50–75% | 都還很早期 |
| [WaitingAds](https://www.waitingads.com/) | 官網只剩一個 Portal 標題，抓不到內容 | — | — | — | 可能已轉型或停擺 |

## 等待娛樂（非廣告）

| 產品 | 做法 | 觸發方式 | 狀態 |
|---|---|---|---|
| [Meanwaile](https://github.com/uurien/meanwaile) | 選單列 popup 小遊戲，有 Agents 分頁顯示 Agent 狀態 | Claude Code HTTP hooks＋Codex command hooks（`UserPromptSubmit`、`Stop`、`PermissionRequest` 等）；本機 :3821 hook server；用鍵盤滑鼠閒置偵測 | Electron，3 stars |
| [microtaskrr](https://github.com/whoisyurii/microtaskrr) | 選單列小遊戲視窗，Esc 回終端機 | 只支援 Claude Code 的 `UserPromptSubmit`、`PreCompact` | Tauri／Rust，2 stars，Codex 在 roadmap |

## 對 WhileAI 的啟示

- **版位：** 競品搶的是「一行 spinner 文字」，靠 patch 第三方工具的 UI 實現，供應商隨時可以擋。WhileAI 走 Codex 官方 hooks＋獨立的小卡片，比較穩，但卡片比一行字更打擾人，所以一定要有延遲顯示、頻率上限，以及 Agent 需要你時立刻收起。原型已經這樣做。
- **定位：** 不要跟它們比分潤。WhileAI 的價值應該是「我想知道其他工程師怎麼選」，靠 Pulse 的同儕結果吸引人，贊助只是附帶。
- **商業：** 既然單純曝光的 CPM 已被壓到個位數美元，就要更早驗證 Sponsored Pulse（贊助一題研究題）。它賣的是合格回答，而不是曝光。
- **待查：** 這些競品的真實安裝數、留存、廣告主續約率。可以實際安裝 adline 或 WaitSpin 體驗，並以廣告主身分詢價。
