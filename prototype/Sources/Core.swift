// 資料模型、本機儲存、後端 API
import Foundation

let eventNote = Notification.Name("ai.whileai.agent-event")
let dataDir = ProcessInfo.processInfo.environment["WHILEAI_DATA_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whileai")

enum Agent: String {
    case codex
    case claudeCode = "claude-code"

    var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

// MARK: - 資料模型（對應後端 API）

struct Question: Codable, Equatable, Identifiable {
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
    // 以下欄位由較新的後端提供；舊後端沒有時用預設值
    var kind: String? = nil           // choice | multi | scale | text
    var anonymous: Bool? = nil
    var live: Bool? = nil             // 回答後立刻看結果
    var scaleLow: String? = nil
    var scaleHigh: String? = nil
    var myAnswered: Bool? = nil
    var myVotes: [Int]? = nil         // 多選題
    var myText: String? = nil         // 文字題
    var voters: [[String]]? = nil     // 具名題：各選項的回答者
    var texts: [TextAnswer]? = nil    // 文字題的回答
    var drawings: [Drawing]? = nil    // 畫圖題的回答
    var reactions: [Reaction]? = nil  // 看結果時大家按的表情（只有數量）
    var myReaction: String? = nil

    var qKind: String { kind ?? "choice" }
    var isAnonymous: Bool { anonymous ?? true }
    var isLive: Bool { live ?? false }
    var answered: Bool { myAnswered ?? (myVote != nil) }
    var hasResults: Bool { results != nil || texts != nil || drawings != nil }

    func isMyChoice(_ i: Int) -> Bool { myVote == i || (myVotes?.contains(i) ?? false) }

    var kindSymbol: String {
        switch qKind {
        case "multi": return "checklist"
        case "scale": return "gauge.with.dots.needle.33percent"
        case "text": return "text.bubble"
        case "draw": return "scribble.variable"
        default: return "circle.inset.filled"
        }
    }

    var kindLabel: String {
        switch qKind {
        case "multi": return "多選"
        case "scale": return "評分"
        case "text": return "文字"
        case "draw": return "畫圖"
        default: return "單選"
        }
    }
}

/// 從邀請訊息、邀請連結或單純的邀請碼裡，抓出 8 碼邀請碼
func extractInviteCode(_ raw: String) -> String? {
    let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    let text = raw.uppercased()
    for pattern in ["/J/([A-Z0-9]{8})", "JOIN/([A-Z0-9]{8})", "SETUP\\.SH\\s+([A-Z0-9]{8})", "邀請碼[：:\\s]*([A-Z0-9]{8})"] {
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            return String(text[r])
        }
    }
    let bare = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return bare.count == 8 && bare.allSatisfy({ alphabet.contains($0) }) ? bare : nil
}

struct Reaction: Codable, Equatable {
    let emoji: String
    let count: Int
}

struct TextAnswer: Codable, Equatable {
    let text: String
    let name: String?
}

/// 畫圖題的一筆：c = 顏色編號、w = 粗細（1 細、2 粗）、p = [x1, y1, x2, y2, ...]
/// 座標是 0–1000 的整數，畫布寬 1000、高 700。存筆畫而不是圖片，資料小、放大也不會糊。
struct Stroke: Codable, Equatable {
    var c: Int
    var w: Int
    var p: [Int]

    static let canvasSize = CGSize(width: 1000, height: 700)
    static let maxPoints = 3500        // 後端上限是 4000，留一點餘裕

    var json: [String: Any] { ["c": c, "w": w, "p": p] }
}

struct Drawing: Codable, Equatable {
    let strokes: [Stroke]
    let name: String?
}

// 出題範本：把常見情境的設定一次帶入，內容可以再改
struct AskTemplate: Identifiable, Equatable {
    let id: String
    let label: String
    let kind: String
    let text: String
    let options: [String]
    let anonymous: Bool
    let live: Bool
    let hours: Double
    var low = ""
    var high = ""

    var symbol: String { String(label.prefix(while: { $0 != " " })) }
    var name: String { String(label.drop(while: { $0 != " " }).dropFirst()) }

    static let all: [AskTemplate] = [
        AskTemplate(id: "custom", label: "✏️ 自訂", kind: "choice", text: "", options: ["", ""],
                    anonymous: true, live: false, hours: 24),
        AskTemplate(id: "lunch", label: "🍱 午餐", kind: "choice", text: "中午吃什麼？",
                    options: ["便當", "麵", "輕食", "都可以"], anonymous: false, live: true, hours: 1),
        AskTemplate(id: "plus1", label: "🙋 揪團 +1", kind: "choice", text: "誰要一起去買咖啡？",
                    options: ["+1", "這次不了"], anonymous: false, live: true, hours: 0.5),
        AskTemplate(id: "decide", label: "⚡ 快速決定", kind: "choice", text: "",
                    options: ["贊成", "反對", "都可以"], anonymous: true, live: true, hours: 4),
        AskTemplate(id: "time", label: "🗓 喬時間", kind: "multi", text: "幾點開會方便？（可複選）",
                    options: ["10:00", "14:00", "16:00"], anonymous: false, live: true, hours: 4),
        AskTemplate(id: "mood", label: "🌡 心情", kind: "scale", text: "這週工作順不順？", options: [],
                    anonymous: true, live: false, hours: 24, low: "很卡", high: "很順"),
        AskTemplate(id: "rant", label: "🤐 匿名吐槽", kind: "text", text: "Agent 今天做過最蠢的事？", options: [],
                    anonymous: true, live: false, hours: 24),
        AskTemplate(id: "draw", label: "🎨 畫圖", kind: "draw", text: "用畫的：你現在的心情", options: [],
                    anonymous: true, live: false, hours: 24),
    ]
}

struct Feed: Codable {
    let pending: [Question]
    let results: [Question]
    var mine: [Question]? = nil       // 我出的、還在進行中的題目
}

struct Group: Codable, Equatable, Identifiable {
    let id: Int
    let name: String
    let inviteCode: String
    let inviteUrl: String
    let memberCount: Int
    let muted: Bool
}

struct GroupDetail: Codable {
    let group: Group
    let questions: [Question]
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
    var lastGroupId: Int?             // 上次出題的群組，下次出題時預設選它
    var skippedByDay: [String: [Int]] = [:]   // 今天略過的題目：當天不再自動跳出
    var skipStreak = 0                // 連續略過幾次（回答任何一題就歸零）
    var skipStreakDay: String?
    var quietDay: String?             // 這一天只通知開獎，不再跳題目
    var firstSeen: Double?            // 第一次啟動的時間；剛安裝的前幾分鐘不跳卡片
    var pausedUntil: Double?          // 暫停到什麼時候

    init() {}
    init(from decoder: Decoder) throws {   // 舊版 state.json 沒有新欄位時用預設值
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seenResults = try c.decodeIfPresent([Int].self, forKey: .seenResults) ?? []
        shownByDay = try c.decodeIfPresent([String: [Int]].self, forKey: .shownByDay) ?? [:]
        onboardingShown = try c.decodeIfPresent(Bool.self, forKey: .onboardingShown) ?? false
        lastGroupId = try c.decodeIfPresent(Int.self, forKey: .lastGroupId)
        skippedByDay = try c.decodeIfPresent([String: [Int]].self, forKey: .skippedByDay) ?? [:]
        skipStreak = try c.decodeIfPresent(Int.self, forKey: .skipStreak) ?? 0
        skipStreakDay = try c.decodeIfPresent(String.self, forKey: .skipStreakDay)
        quietDay = try c.decodeIfPresent(String.self, forKey: .quietDay)
        firstSeen = try c.decodeIfPresent(Double.self, forKey: .firstSeen)
        pausedUntil = try c.decodeIfPresent(Double.self, forKey: .pausedUntil)
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

    static func bundleString(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty else { return nil }
        return s
    }

    // 伺服器網址：環境變數 > config.json > 打包時寫入的預設值 > 本機
    static var serverURL: String {
        if let env = ProcessInfo.processInfo.environment["WHILEAI_SERVER"] { return env }
        struct Config: Codable { let server: String }
        if let s = load("config.json", as: Config.self)?.server { return s }
        return bundleString("WhileAIDefaultServer") ?? "http://127.0.0.1:8787"
    }

    // 邀請訊息裡的「還沒安裝？」連結
    static var installURL: String? { bundleString("WhileAIInstallURL") }

    // 驗證 Codex（CLI／桌面 App）與 Claude Code 有沒有送出 hook 事件：只記時間與事件名稱
    static func logHook(_ event: String) {
        let url = dataDir.appendingPathComponent("hooks.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        append(Data("\(ISO8601DateFormatter().string(from: Date())) \(event)\n".utf8), to: url)
    }

    // H1／H2 驗證用的互動紀錄
    static func log(_ type: String, question: Int? = nil, extra: [String: Any] = [:]) {
        var row: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "type": type]
        if let q = question { row["question"] = q }
        row.merge(extra) { $1 }
        guard var line = try? JSONSerialization.data(withJSONObject: row) else { return }
        line.append(0x0A)
        append(line, to: dataDir.appendingPathComponent("events.jsonl"))
    }

    static func append(_ data: Data, to url: URL) {
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: url)
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
