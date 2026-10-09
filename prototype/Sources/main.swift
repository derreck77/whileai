// WhileAI 原型 v0.2：群組 × 互相出題
// Codex 工作時，在右上角送出群組成員出的題目；截止後在下一次等待時開獎。
//
// 執行模式：
//   WhileAI                 選單列 App（常駐）
//   WhileAI hook            給 Codex hooks 呼叫：讀 stdin，只轉送事件名稱給常駐 App 後立即結束
//   WhileAI snapshot <dir>  開發用：把卡片的各種狀態渲染成 PNG
import AppKit
import SwiftUI

let eventNote = Notification.Name("ai.whileai.agent-event")
let dataDir = ProcessInfo.processInfo.environment["WHILEAI_DATA_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whileai")

enum Agent: String {
    case codex
    case claudeCode = "claude-code"

    var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

// MARK: - Hook 模式

if CommandLine.arguments.dropFirst().first == "hook" {
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    // 隱私：只取 hook_event_name 與 session_id。prompt、cwd、transcript_path、
    // tool_input、last_assistant_message 等工作內容一律不讀取、不保存、不傳送。
    let arg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
    let agent = Agent(rawValue: arg) ?? .codex
    var event = Agent(rawValue: arg) == nil ? arg : ""
    var session = "default"
    if let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
        event = obj["hook_event_name"] as? String ?? event
        session = obj["session_id"] as? String ?? session
    }
    DistributedNotificationCenter.default().postNotificationName(
        eventNote, object: nil, userInfo: ["event": event, "session": session, "agent": agent.rawValue],
        deliverImmediately: true)
    // Codex 的 Stop／Interrupt 不接受純文字輸出；Claude Code 的 PermissionRequest 沒輸出時照常詢問使用者。因此不印任何東西。
    exit(0)
}

// MARK: - 資料模型（對應後端 API）

struct Question: Codable, Equatable {
    let id: Int
    let groupId: Int
    let groupName: String
    let authorName: String
    let isMine: Bool
    let text: String
    let options: [String]
    let closesAt: Double
    let closed: Bool
    let answeredCount: Int
    let memberCount: Int
    let myVote: Int?
    let results: [Int]?
    let hiddenReason: String?
}

struct Feed: Codable {
    let pending: [Question]
    let results: [Question]
}

struct Group: Codable {
    let id: Int
    let name: String
    let inviteCode: String
    let inviteUrl: String
    let memberCount: Int
    let muted: Bool
}

struct UserInfo: Codable {
    let id: Int
    let name: String
}

struct Me: Codable {
    let user: UserInfo
    let groups: [Group]
}

struct Identity: Codable {
    let token: String
    var name: String
    var server: String?   // 這組身分屬於哪個伺服器；舊版沒有這個欄位時視為本機伺服器
}

// MARK: - 本機儲存（身分、看過哪些開獎、每日顯示上限、互動紀錄；不含任何工作內容）

struct LocalState: Codable {
    var seenResults: [Int] = []
    var shownByDay: [String: [Int]] = [:]
    var onboardingShown = false

    init() {}
    init(from decoder: Decoder) throws {   // 舊版 state.json 沒有新欄位時用預設值
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seenResults = try c.decodeIfPresent([Int].self, forKey: .seenResults) ?? []
        shownByDay = try c.decodeIfPresent([String: [Int]].self, forKey: .shownByDay) ?? [:]
        onboardingShown = try c.decodeIfPresent(Bool.self, forKey: .onboardingShown) ?? false
    }
}

enum Store {
    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = dataDir.appendingPathComponent(name)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
        // identity.json 含 token，只給自己讀寫
        if name == "identity.json" {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static var serverURL: String {
        if let env = ProcessInfo.processInfo.environment["WHILEAI_SERVER"] { return env }
        struct Config: Codable { let server: String }
        if let s = load("config.json", as: Config.self)?.server { return s }
        if let s = Bundle.main.object(forInfoDictionaryKey: "WhileAIDefaultServer") as? String, !s.isEmpty { return s }
        return "http://127.0.0.1:8787"
    }

    // 驗證 Codex（CLI／桌面 App）有沒有送出 hook 事件：只記時間與事件名稱
    static func logHook(_ event: String) {
        let url = dataDir.appendingPathComponent("hooks.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // H1／H2 驗證用的互動紀錄
    static func log(_ type: String, question: Int? = nil, extra: [String: Any] = [:]) {
        var row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "type": type]
        if let q = question { row["question"] = q }
        row.merge(extra) { $1 }
        guard var line = try? JSONSerialization.data(withJSONObject: row) else { return }
        line.append(0x0A)
        let url = dataDir.appendingPathComponent("events.jsonl")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(line); try? fh.close()
        } else {
            try? line.write(to: url)
        }
    }
}

// MARK: - API

enum APIError: Error { case message(String) }

final class API {
    var token: String?
    let base: String
    var onUnauthorized: (() -> Void)?
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(base: String) { self.base = base }

    func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                            as: T.Type, done: @escaping (Result<T, APIError>) -> Void) {
        guard let url = URL(string: base + path) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body = body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: Result<T, APIError>
            if let err = err {
                result = .failure(.message("連不上 WhileAI 伺服器（\(err.localizedDescription)）"))
            } else if let http = resp as? HTTPURLResponse, let data = data {
                if http.statusCode == 200, let v = try? self.decoder.decode(T.self, from: data) {
                    result = .success(v)
                } else {
                    if http.statusCode == 401, self.token != nil {
                        DispatchQueue.main.async { self.onUnauthorized?() }
                    }
                    let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    result = .failure(.message(msg ?? "伺服器錯誤（\(http.statusCode)）"))
                }
            } else {
                result = .failure(.message("伺服器沒有回應"))
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}

// MARK: - 卡片狀態與畫面

enum Phase { case working, done }

final class Model: ObservableObject {
    @Published var question: Question?
    @Published var onboarding = false
    @Published var agentName = "Codex"
    @Published var phase: Phase = .working
    @Published var sending = false
    @Published var error: String?

    var onSkip: () -> Void = {}
    var onVote: (Int) -> Void = { _ in }
    var onCreateGroup: () -> Void = {}
    var onJoin: () -> Void = {}
}

struct CardView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(m.phase == .done ? "✓ \(m.agentName) 完成了，回去看看吧" : "\(m.agentName) 工作中 · 隨時可略過")
                    .font(.caption)
                    .foregroundStyle(m.phase == .done ? Color.green : Color.secondary)
                Spacer()
                Button(action: m.onSkip) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("略過")
            }

            if m.onboarding {
                Text("WhileAI 已連上 \(m.agentName) ✓")
                    .font(.headline)
                Text("建立一個群組，把邀請連結貼給同事。之後大家等 Agent 時，就能互相出題、匿名回答。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("建立群組…", action: m.onCreateGroup)
                    Button("輸入邀請碼…", action: m.onJoin)
                }
            } else if let q = m.question {
                Text(meta(q))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(q.text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if q.closed {
                    result(q)
                } else if let mine = q.myVote {
                    Text("✓ 你選了「\(q.options[mine])」· 開獎時通知你")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Text("\(q.answeredCount)／\(q.memberCount) 人已答 · \(timeLeft(q.closesAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ask(q)
                }
                if let err = m.error {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }

    func meta(_ q: Question) -> String {
        q.closed ? "🎉 開獎 · \(q.groupName)" : "\(q.groupName) · \(q.authorName) 出題"
    }

    @ViewBuilder func ask(_ q: Question) -> some View {
        VStack(spacing: 6) {
            ForEach(q.options.indices, id: \.self) { i in
                Button(action: { m.onVote(i) }) {
                    Text(q.options[i]).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(m.sending)
            }
            Text("匿名 · ≥3 人回答才公開 · \(q.answeredCount)／\(q.memberCount) 人已答 · \(timeLeft(q.closesAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder func result(_ q: Question) -> some View {
        if let counts = q.results {
            let total = max(counts.reduce(0, +), 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(q.options.indices, id: \.self) { i in
                    let pct = Double(counts[safe: i] ?? 0) / Double(total)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(q.options[i] + (i == q.myVote ? "（你）" : "")).font(.caption)
                            Spacer()
                            Text("\(Int((pct * 100).rounded()))% · \(counts[safe: i] ?? 0) 票")
                                .font(.caption.monospacedDigit())
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(i == q.myVote ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .frame(width: g.size.width * pct)
                            }
                        }
                        .frame(height: 5)
                    }
                }
                Text("\(q.answeredCount)／\(q.memberCount) 人回答 · 匿名")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text(q.hiddenReason ?? "結果未公開")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

func timeLeft(_ ts: Double) -> String {
    let s = ts - Date().timeIntervalSince1970
    if s <= 0 { return "已截止" }
    if s < 3600 { return "剩 \(Int((s / 60).rounded(.up))) 分鐘" }
    if s < 86400 { return "剩 \(Int((s / 3600).rounded())) 小時" }
    return "剩 \(Int((s / 86400).rounded())) 天"
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// 無邊框面板預設無法成為 key window，按鈕會吃不到第一下點擊。
// 搭配 .nonactivatingPanel，成為 key 時不會把 Codex 的視窗切到背景。
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = Model()
    let api = API(base: Store.serverURL)
    var panel: CardPanel!
    var statusItem: NSStatusItem!

    var identity: Identity?
    var me: Me?
    var feed = Feed(pending: [], results: [])
    var state = Store.load("state.json", as: LocalState.self) ?? LocalState()
    var lastError: String?
    var pendingJoinCode: String?
    var localServer: Process?

    var activeSessions: [String: (agent: Agent, last: Date)] = [:]
    // Claude Code 按 Esc 中斷時不會送 Stop；超過這個時間沒有事件的 session 視為已結束
    let staleAfter: TimeInterval = 45 * 60
    var skippedThisWait = Set<Int>()
    var pendingShow: DispatchWorkItem?
    var pendingHide: DispatchWorkItem?
    var lastShown = Date.distantPast
    var pausedUntil = Date.distantPast

    // 低干擾設定：任務超過 showDelay 秒才顯示；兩張卡片之間至少隔 minGap 秒；每天最多 dailyLimit 道新題目
    let showDelay = Double(ProcessInfo.processInfo.environment["WHILEAI_DELAY"] ?? "") ?? 8
    let minGap = Double(ProcessInfo.processInfo.environment["WHILEAI_GAP"] ?? "") ?? 180
    let dailyLimit = 5

    func applicationWillFinishLaunching(_ note: Notification) {
        // whileai://join/<邀請碼>
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Store.ensureDir()
        setupPanel()
        setupMenu()

        model.onSkip = { [weak self] in self?.skip() }
        model.onVote = { [weak self] i in self?.vote(i) }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onAgentEvent(_:)), name: eventNote, object: nil,
            suspensionBehavior: .deliverImmediately)

        model.onCreateGroup = { [weak self] in self?.hide(reason: nil); self?.openWeb(path: "/") }
        model.onJoin = { [weak self] in self?.hide(reason: nil); self?.promptJoin() }

        ensureLocalServer { [weak self] in
            guard let self = self else { return }
            let saved = Store.load("identity.json", as: Identity.self)
            // 換了伺服器（例如從本機測試改成正式網址）→ 舊身分在新伺服器不存在，重新設定暱稱
            self.identity = (saved?.server ?? "http://127.0.0.1:8787") == self.api.base ? saved : nil
            self.api.onUnauthorized = { [weak self] in self?.identityRejected() }
            self.offerAgentSetup {
                if self.identity == nil { self.askNickname() }
                self.api.token = self.identity?.token
                self.refresh()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.pruneStaleSessions()
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        localServer?.terminate()
    }

    // 伺服器設在本機（127.0.0.1／localhost）卻連不上時，用 App 內附的後端自己啟動一個。
    // 資料庫放在 ~/.whileai/server.db。部署到公開網址後就不會走到這裡。
    func ensureLocalServer(then done: @escaping () -> Void) {
        guard let url = URL(string: api.base), ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              let script = Bundle.main.url(forResource: "server", withExtension: "py", subdirectory: "server")
        else { done(); return }
        var probe = URLRequest(url: url.appendingPathComponent("api/feed"), timeoutInterval: 1.5)
        probe.httpMethod = "GET"
        URLSession.shared.dataTask(with: probe) { _, resp, _ in
            DispatchQueue.main.async {
                if resp != nil { done(); return }    // 已經有伺服器在跑
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = [script.path]
                var env = ProcessInfo.processInfo.environment
                env["PORT"] = String(url.port ?? 8787)
                env["DB_PATH"] = dataDir.appendingPathComponent("server.db").path
                p.environment = env
                let logPath = dataDir.appendingPathComponent("server.log").path
                FileManager.default.createFile(atPath: logPath, contents: nil)
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice
                do {
                    try p.run()
                    self.localServer = p
                } catch {
                    self.lastError = "無法啟動本機伺服器：\(error.localizedDescription)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
            }
        }.resume()
    }

    // MARK: 身分

    func askNickname() {
        NSApp.activate(ignoringOtherApps: true)
        guard let name = prompt(title: "歡迎使用 WhileAI",
                                message: "取一個暱稱。你出題時其他成員會看到它；你的答案永遠匿名。",
                                placeholder: "暱稱"), !name.isEmpty else {
            lastError = "尚未設定暱稱"
            return
        }
        struct Created: Codable { let token: String; let user: UserInfo }
        api.call("POST", "/api/users", body: ["name": name], as: Created.self) { [weak self] r in
            switch r {
            case .success(let c):
                self?.identity = Identity(token: c.token, name: c.user.name, server: self?.api.base)
                Store.save(self?.identity, to: "identity.json")
                self?.api.token = c.token
                self?.refresh()
                if let code = self?.pendingJoinCode { self?.join(code: code) }
            case .failure(.message(let m)):
                self?.alert("無法建立身分", m)
            }
        }
    }

    func identityRejected() {
        guard identity != nil else { return }
        identity = nil
        api.token = nil
        me = nil
        feed = Feed(pending: [], results: [])
        updateBadge()
        askNickname()
    }

    // MARK: 連接 Codex 與 Claude Code（給朋友用的打包版：App 自己設定 hooks）

    var executablePath: String { Bundle.main.executablePath ?? "" }

    func agentsConnected() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".codex/hooks.json", ".claude/settings.json"].contains { rel in
            (try? String(contentsOf: home.appendingPathComponent(rel), encoding: .utf8))?.contains(executablePath) == true
        }
    }

    // 打包版第一次開啟時詢問；開發時用 install.sh 安裝的 App 已經連接過，不會再問
    func offerAgentSetup(then done: @escaping () -> Void) {
        guard Bundle.main.url(forResource: "hooks_config", withExtension: "py") != nil, !agentsConnected() else {
            done(); return
        }
        if executablePath.contains("/AppTranslocation/") || !executablePath.contains("/Applications/") {
            alert("請先把 WhileAI 移到「應用程式」資料夾",
                  "把 WhileAI 從「下載」拖到「應用程式」後再打開。這樣 Codex 和 Claude Code 才能找到它。")
            done(); return
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "連接 Codex 與 Claude Code？"
        a.informativeText = """
        WhileAI 需要知道 Agent 什麼時候開始和結束工作，才能在等待時送出題目。

        會修改：
        • ~/.codex/hooks.json 與 config.toml（信任 WhileAI 的 hooks）
        • ~/.claude/settings.json
        修改前會先備份。WhileAI 只接收「開始／完成」事件，不會讀取你的程式碼或 prompt。
        """
        a.addButton(withTitle: "連接")
        a.addButton(withTitle: "稍後")
        if a.runModal() == .alertFirstButtonReturn { connectAgents() }
        done()
    }

    @objc func connectAgents() {
        guard let config = Bundle.main.url(forResource: "hooks_config", withExtension: "py"),
              let trust = Bundle.main.url(forResource: "trust_hooks", withExtension: "py") else { return }
        func run(_ args: [String]) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            return (p.terminationStatus, out)
        }
        let (code, out) = run([config.path, "install", executablePath])
        guard code == 0 else { alert("連接失敗", out); return }
        let (tcode, tout) = run([trust.path])
        installLoginItem()
        Store.log("agents_connected")
        alert("已連接 ✓", out + "\n" + (tcode == 0 ? tout : "Codex 的 hooks 需要手動信任：在 Codex CLI 輸入 /hooks。\n\(tout)"))
    }

    // 登入時自動啟動（寫一個 LaunchAgent；下次登入生效）
    func installLoginItem() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "ai.whileai.app", "ProgramArguments": [executablePath],
                                    "RunAtLoad": true, "ProcessType": "Interactive"]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: dir.appendingPathComponent("ai.whileai.app.plist"))
        }
    }

    // MARK: 同步

    func refresh(then: (() -> Void)? = nil) {
        guard identity != nil else { then?(); return }
        api.call("GET", "/api/feed", as: Feed.self) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let f): self.feed = f; self.lastError = nil
            case .failure(.message(let m)): self.lastError = m
            }
            self.updateBadge()
            then?()
        }
        api.call("GET", "/api/me", as: Me.self) { [weak self] r in
            if case .success(let me) = r { self?.me = me }
        }
    }

    func updateBadge() {
        let n = feed.pending.count
        statusItem.button?.title = n > 0 ? " \(n)" : ""
    }

    // MARK: Agent 事件（Codex、Claude Code）

    @objc func onAgentEvent(_ note: Notification) {
        let event = note.userInfo?["event"] as? String ?? ""
        let agent = Agent(rawValue: note.userInfo?["agent"] as? String ?? "") ?? .codex
        let session = agent.rawValue + ":" + (note.userInfo?["session"] as? String ?? "default")
        Store.logHook("\(agent.rawValue) \(event)")
        pruneStaleSessions()

        switch event {
        case "UserPromptSubmit":
            if activeSessions.isEmpty { skippedThisWait.removeAll() }
            activeSessions[session] = (agent, Date())
            updateAgentName(fallback: agent)
            refresh { [weak self] in self?.scheduleShow() }
        case "PermissionRequest", "Notification":
            // 工作優先：Agent 需要你的時候立刻收起卡片。
            // Claude Code 的 Notification 只註冊了 permission_prompt 等「需要你」的類型。
            activeSessions[session]?.last = Date()
            cancelShow()
            hide(reason: "agent_needs_you")
        case "Stop", "Interrupt", "SessionEnd", "StopFailure":
            activeSessions[session] = nil
            updateAgentName(fallback: agent)
            if activeSessions.isEmpty {
                cancelShow()
                if panel.isVisible { agentFinished() }
            }
        default:
            break
        }
    }

    func pruneStaleSessions() {
        let before = activeSessions.count
        activeSessions = activeSessions.filter { Date().timeIntervalSince($0.value.last) < staleAfter }
        if before > 0 && activeSessions.isEmpty {
            cancelShow()
            if panel.isVisible && model.phase == .working { hide(reason: nil) }
        }
    }

    // 只有一種 Agent 在跑時顯示它的名字；同時有 Codex 和 Claude Code 時顯示「Agent」
    func updateAgentName(fallback: Agent) {
        let running = Set(activeSessions.values.map { $0.agent })
        model.agentName = running.count > 1 ? "Agent" : (running.first ?? fallback).displayName
    }

    func scheduleShow() {
        guard pendingShow == nil, !panel.isVisible, !activeSessions.isEmpty else { return }
        guard Date() >= pausedUntil, Date().timeIntervalSince(lastShown) >= minGap else { return }
        guard nextQuestion() != nil || needsOnboarding else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingShow = nil
            guard !self.activeSessions.isEmpty else { return }
            if let q = self.nextQuestion() { self.show(q) } else if self.needsOnboarding { self.showOnboarding() }
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    func cancelShow() {
        pendingShow?.cancel()
        pendingShow = nil
    }

    func agentFinished() {
        model.phase = .done
        Store.log("agent_done_while_shown", question: model.question?.id)
        let reading = model.question?.closed == true || model.question?.myVote != nil
        scheduleHide(after: reading ? 5 : 2.5)
    }

    // MARK: 選題：先開獎、再待答題

    var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func nextQuestion() -> Question? {
        if let r = feed.results.first(where: { !state.seenResults.contains($0.id) }) { return r }
        let shownToday = state.shownByDay[today] ?? []
        return feed.pending.first { q in
            !skippedThisWait.contains(q.id) && (shownToday.contains(q.id) || shownToday.count < dailyLimit)
        }
    }

    // 已設定暱稱、還沒加入任何群組、也還沒看過引導 → 第一次等待時顯示一次
    var needsOnboarding: Bool {
        identity != nil && me != nil && me?.groups.isEmpty == true && !state.onboardingShown
    }

    func showOnboarding() {
        pendingHide?.cancel()
        model.question = nil
        model.onboarding = true
        model.phase = .working
        lastShown = Date()
        state.onboardingShown = true
        Store.save(state, to: "state.json")
        present()
        Store.log("onboarding_shown")
    }

    func present() {
        resizePanel(anchorTop: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func show(_ q: Question) {
        pendingHide?.cancel()
        model.onboarding = false
        model.question = q
        model.phase = .working
        model.error = nil
        model.sending = false
        lastShown = Date()

        if q.closed {
            state.seenResults.append(q.id)
        } else {
            var shown = state.shownByDay[today] ?? []
            if !shown.contains(q.id) { shown.append(q.id) }
            state.shownByDay = [today: shown]   // 只保留今天
        }
        Store.save(state, to: "state.json")

        present()
        Store.log(q.closed ? "result_shown" : "shown", question: q.id, extra: ["agent": model.agentName])
    }

    func resizePanel(anchorTop: Bool) {
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if anchorTop {
            let old = panel.frame
            panel.setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height),
                           display: true)
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
        }
    }

    func scheduleHide(after seconds: Double) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide(reason: nil) }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide(reason: String?) {
        guard panel.isVisible else { return }
        pendingHide?.cancel()
        if let reason = reason { Store.log(reason, question: model.question?.id) }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.panel.orderOut(nil) })
    }

    // MARK: 使用者動作

    func skip() {
        if model.onboarding { model.onboarding = false }
        if let q = model.question, !q.closed { skippedThisWait.insert(q.id) }
        hide(reason: "skipped")
    }

    func vote(_ i: Int) {
        guard let q = model.question, !model.sending else { return }
        model.sending = true
        model.error = nil
        api.call("POST", "/api/questions/\(q.id)/vote", body: ["option": i], as: Question.self) { [weak self] r in
            guard let self = self else { return }
            self.model.sending = false
            switch r {
            case .success(let updated):
                self.model.question = updated
                self.feed = Feed(pending: self.feed.pending.filter { $0.id != q.id }, results: self.feed.results)
                if updated.closed {   // 我是最後一個回答的人 → 直接看到開獎
                    self.state.seenResults.append(updated.id)
                    Store.save(self.state, to: "state.json")
                }
                self.updateBadge()
                Store.log("voted", question: q.id, extra: ["option": i])
                if self.model.phase == .done { self.scheduleHide(after: 5) }
            case .failure(.message(let m)):
                self.model.error = m
            }
            DispatchQueue.main.async { self.resizePanel(anchorTop: true) }
        }
    }

    // MARK: 加入群組

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s), url.host == "join" else { return }
        let code = url.lastPathComponent.uppercased()
        if identity == nil { pendingJoinCode = code } else { join(code: code) }
    }

    @objc func promptJoin() {
        NSApp.activate(ignoringOtherApps: true)
        if let code = prompt(title: "加入群組", message: "輸入同伴給你的 8 碼邀請碼", placeholder: "邀請碼"),
           !code.isEmpty {
            join(code: code.uppercased())
        }
    }

    func join(code: String) {
        pendingJoinCode = nil
        struct Detail: Codable { let group: Group }
        api.call("POST", "/api/invites/\(code)/join", as: Detail.self) { [weak self] r in
            switch r {
            case .success(let d):
                self?.refresh()
                self?.notify("已加入「\(d.group.name)」", "等 Codex 時就會看到群組裡的題目。")
                Store.log("joined_group")
            case .failure(.message(let m)):
                self?.alert("無法加入群組", m)
            }
        }
    }

    // MARK: 選單

    func setupPanel() {
        panel = CardPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                          backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CardView(m: model))
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "WhileAI")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // 每次打開選單時重建，內容永遠是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, _ obj: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = obj
            return i
        }

        if let err = lastError {
            let e = item("⚠︎ \(err)", nil)
            e.isEnabled = false
            menu.addItem(e)
            menu.addItem(.separator())
        }

        menu.addItem(item(feed.pending.isEmpty ? "沒有待答題" : "待答題（\(feed.pending.count)）", nil))
        for q in feed.pending.prefix(8) {
            menu.addItem(item("   \(q.groupName)：\(q.text.prefix(28))", #selector(openQuestion(_:)), q.id))
        }
        let unseen = feed.results.filter { !state.seenResults.contains($0.id) }
        if !unseen.isEmpty {
            menu.addItem(item("新開獎（\(unseen.count)）", nil))
            for q in unseen.prefix(5) {
                menu.addItem(item("   🎉 \(q.text.prefix(30))", #selector(openQuestion(_:)), q.id))
            }
        }

        menu.addItem(.separator())
        let groups = me?.groups ?? []
        let groupsItem = item(groups.isEmpty ? "我的群組（尚未加入）" : "我的群組", nil)
        let sub = NSMenu()
        for g in groups {
            let gi = item("\(g.name)（\(g.memberCount) 人）\(g.muted ? " · 靜音中" : "")", nil)
            let gm = NSMenu()
            gm.addItem(item("出題／看結果…", #selector(openGroupWeb(_:)), g.id))
            gm.addItem(item("複製邀請連結", #selector(copyInvite(_:)), g.inviteUrl))
            gm.addItem(item(g.muted ? "取消靜音" : "靜音這個群組", #selector(toggleMute(_:)), g.id))
            gi.submenu = gm
            sub.addItem(gi)
        }
        if !groups.isEmpty { sub.addItem(.separator()) }
        sub.addItem(item("建立新群組…", #selector(openHomeWeb)))
        sub.addItem(item("輸入邀請碼加入…", #selector(promptJoin)))
        groupsItem.submenu = sub
        menu.addItem(groupsItem)

        menu.addItem(.separator())
        menu.addItem(item(Date() < pausedUntil ? "恢復顯示卡片" : "暫停 1 小時", #selector(togglePause)))
        menu.addItem(item("暱稱：\(identity?.name ?? "未設定")", identity == nil ? #selector(setNickname) : nil))
        if Bundle.main.url(forResource: "hooks_config", withExtension: "py") != nil && !agentsConnected() {
            menu.addItem(item("連接 Codex 與 Claude Code…", #selector(connectAgents)))
        }
        menu.addItem(item("打開資料夾（互動紀錄）", #selector(openDataDir)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "結束 WhileAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func openQuestion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int,
              let q = (feed.pending + feed.results).first(where: { $0.id == id }) else { return }
        show(q)
    }

    @objc func setNickname() { askNickname() }

    @objc func openHomeWeb() { openWeb(path: "/") }

    @objc func openGroupWeb(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? Int { openWeb(path: "/g/\(id)") }
    }

    // App → 網頁：先換一次性登入碼，網頁再用它換自己的 token；App 的 token 不會出現在網址
    func openWeb(path: String) {
        struct Handoff: Codable { let code: String }
        api.call("POST", "/api/handoff", as: Handoff.self) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let h):
                if let url = URL(string: "\(self.api.base)\(path)?handoff=\(h.code)") { NSWorkspace.shared.open(url) }
            case .failure(.message(let m)):
                self.alert("無法開啟網頁", m)
            }
        }
    }

    @objc func copyInvite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let g = me?.groups.first(where: { $0.id == id }) else { return }
        struct OK: Codable { let ok: Bool }
        api.call("POST", "/api/groups/\(id)/mute", body: ["muted": !g.muted], as: OK.self) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func togglePause() {
        if Date() < pausedUntil {
            pausedUntil = .distantPast
            Store.log("resumed")
        } else {
            pausedUntil = Date().addingTimeInterval(3600)
            cancelShow()
            hide(reason: nil)
            Store.log("paused")
        }
    }

    @objc func openDataDir() {
        NSWorkspace.shared.open(dataDir)
    }

    // MARK: 小工具

    func prompt(title: String, message: String, placeholder: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        a.accessoryView = field
        a.addButton(withTitle: "確定")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    func notify(_ title: String, _ message: String) {
        alert(title, message)
    }
}

// MARK: - 開發用：卡片快照

if CommandLine.arguments.dropFirst().first == "snapshot" {
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
    let base = Date().timeIntervalSince1970
    func q(myVote: Int?, closed: Bool, results: [Int]?, hidden: String? = nil, answered: Int) -> Question {
        Question(id: 1, groupId: 1, groupName: "後端組", authorName: "小林", isMine: false,
                 text: "下個 sprint 要不要統一改用 Codex？", options: ["要", "不要", "先試一週再說"],
                 closesAt: base + 5 * 3600, closed: closed, answeredCount: answered, memberCount: 8,
                 myVote: myVote, results: results, hiddenReason: hidden)
    }
    let cases: [(String, Question, Phase)] = [
        ("1-ask", q(myVote: nil, closed: false, results: nil, answered: 3), .working),
        ("2-voted", q(myVote: 2, closed: false, results: nil, answered: 4), .working),
        ("3-result", q(myVote: 2, closed: true, results: [2, 1, 5], answered: 8), .done),
        ("4-hidden", q(myVote: 0, closed: true, results: nil, hidden: "回答人數不足 3 人，未公開結果", answered: 2), .working),
        ("5-onboarding", q(myVote: nil, closed: false, results: nil, answered: 0), .working),
    ]
    MainActor.assumeIsolated {
        for (name, question, phase) in cases {
            let m = Model()
            m.question = question
            m.phase = phase
            m.onboarding = name == "5-onboarding"
            let r = ImageRenderer(content: CardView(m: m).padding(20).background(Color(white: 0.92)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent(name + ".png"))
            }
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
