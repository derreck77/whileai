// WhileAI：等 AI Agent 工作的空檔，和朋友互相出題
//
// 執行模式：
//   WhileAI                       選單列 App（常駐）
//   WhileAI hook [codex|claude-code]
//                                 給 Codex／Claude Code hooks 呼叫：讀 stdin，只轉送事件名稱給常駐 App 後立即結束
//   WhileAI snapshot <dir> [--dark]  開發用：把小框框的各個畫面渲染成 PNG
import AppKit
import SwiftUI

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

// MARK: - 開發用：畫面快照

if CommandLine.arguments.dropFirst().first == "snapshot" {
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
    let dark = CommandLine.arguments.contains("--dark")
    let now = Date().timeIntervalSince1970
    func q(_ id: Int, _ text: String, author: String = "小林", mine: Bool = false, kind: String = "choice",
           options: [String] = ["要", "不要", "先試一週再說"], anonymous: Bool = true, live: Bool = false,
           answered: Int = 3, closed: Bool = false, myVote: Int? = nil, results: [Int]? = nil,
           hidden: String? = nil, closes: Double = 5 * 3600) -> Question {
        Question(id: id, groupId: 1, groupName: "後端組", authorName: author, isMine: mine, text: text,
                 options: options, closesAt: now + closes, closed: closed, answeredCount: answered, memberCount: 8,
                 myVote: myVote, results: results, hiddenReason: hidden, kind: kind, anonymous: anonymous, live: live,
                 myAnswered: myVote != nil)
    }
    let pending = [q(1, "下個 sprint 要不要統一改用 Codex？"),
                   q(2, "幾點開會方便？（可複選）", author: "阿凱", kind: "multi", options: ["10:00", "14:00", "16:00"],
                     anonymous: false, live: true)]
    let result = q(3, "要不要把 lint 交給 Agent 自動修？", answered: 8, closed: true, myVote: 2, results: [2, 1, 5])
    let myOpen = q(5, "下午要不要訂飲料？", author: "derreck", mine: true, options: ["要", "不要"],
                   anonymous: false, live: true, answered: 5, myVote: 0, results: [4, 1], closes: 1800)
    let groups = [Group(id: 1, name: "後端組", inviteCode: "K7P3QX9M", inviteUrl: "https://x/j/K7P3QX9M", memberCount: 8, muted: false),
                  Group(id: 2, name: "大學同學", inviteCode: "M2RT8WQA", inviteUrl: "https://x/j/M2RT8WQA", memberCount: 2, muted: true)]
    let me = Me(user: UserInfo(id: 1, name: "derreck"), groups: groups)
    let detail = GroupDetail(group: groups[0], questions: pending + [myOpen, result])

    func model(_ screen: Screen, stack: [Screen] = [.home]) -> Model {
        let m = Model()
        m.preview = true
        m.screen = screen
        m.stack = stack
        m.me = me
        m.feed = Feed(pending: pending, results: [result], mine: [myOpen])
        m.unseenResults = [result]
        m.details = [1: detail, 2: GroupDetail(group: groups[1], questions: [])]
        m.askGroupId = 1
        return m
    }
    func apply(_ m: Model, _ t: AskTemplate) {
        m.askTemplate = t.id; m.askKind = t.kind; m.askText = t.text
        m.askOptions = t.options.isEmpty ? ["", ""] : t.options
        m.askAnonymous = t.anonymous; m.askLive = t.live; m.askHours = t.hours; m.askLow = t.low; m.askHigh = t.high
    }
    var cases: [(String, Model)] = []
    func add(_ name: String, _ screen: Screen, stack: [Screen] = [.home], _ setup: (Model) -> Void = { _ in }) {
        let m = model(screen, stack: stack); setup(m); cases.append((name, m))
    }

    add("01-welcome", .welcome, stack: []) { $0.nickname = "derreck" }
    add("02-home-empty", .home, stack: []) { $0.me = Me(user: UserInfo(id: 1, name: "derreck"), groups: []) }
    add("03-home", .home, stack: [])
    add("04-group", .group(1)) { $0.notice = "已發出。7 位成員會在等 Agent 時看到。" }
    add("05-group-small", .group(2))
    add("06-create", .createGroup) { $0.groupName = "週末黑客松" }
    add("07-join", .join)
    add("08-ask-lunch", .ask) { apply($0, AskTemplate.all[1]) }
    add("09-ask-settings", .ask) { apply($0, AskTemplate.all[5]); $0.askShowSettings = true }
    add("10-ask-small-group", .ask) { apply($0, AskTemplate.all[6]); $0.askGroupId = 2 }
    add("11-question-mine", .question) { $0.question = myOpen }
    add("12-settings", .settings) { $0.nickname = "derreck"; $0.serverLabel = "whileai-production.up.railway.app" }

    add("20-card-choice", .card, stack: []) { $0.question = pending[0]; $0.remaining = 1 }
    add("21-card-multi", .card, stack: []) { $0.question = pending[1]; $0.multiSelection = [0, 2]; $0.agentName = "Claude Code" }
    add("22-card-scale", .card, stack: []) {
        var s = q(12, "這個 sprint 壓力多大？", kind: "scale", options: ["1", "2", "3", "4", "5"], answered: 1)
        s.scaleLow = "很輕鬆"; s.scaleHigh = "快爆了"; $0.question = s
    }
    add("23-card-text", .card, stack: []) {
        $0.question = q(14, "Agent 今天做過最蠢的事？", author: "阿凱", kind: "text", options: [])
        $0.answerText = "把測試全部刪掉，然後說測試都通過了"
    }
    add("24-card-answered-next", .card, stack: []) {
        var a = pending[0]; a.myAnswered = true; $0.question = a; $0.remaining = 2
    }
    add("25-card-named-live", .card, stack: []) {
        var l = q(10, "中午吃什麼？", author: "美玲", options: ["便當", "麵", "輕食"], anonymous: false, live: true,
                  answered: 6, myVote: 0, results: [3, 2, 1], closes: 1800)
        l.voters = [["derreck", "阿凱", "小林"], ["美玲", "Ray"], ["Tina"]]; $0.question = l
    }
    add("26-card-scale-result", .card, stack: []) {
        var s = q(13, "這個 sprint 壓力多大？", kind: "scale", options: ["1", "2", "3", "4", "5"], answered: 7,
                  closed: true, myVote: 3, results: [0, 1, 2, 3, 1])
        s.scaleLow = "很輕鬆"; s.scaleHigh = "快爆了"; $0.question = s; $0.phase = .done
    }
    add("27-card-text-result", .card, stack: []) {
        var t = q(15, "Agent 今天做過最蠢的事？", author: "阿凱", kind: "text", options: [], answered: 3, closed: true)
        t.myAnswered = true
        t.texts = [TextAnswer(text: "把測試全部刪掉，然後說測試都通過了", name: nil),
                   TextAnswer(text: "連續三次 rm -rf node_modules", name: nil),
                   TextAnswer(text: "說做完了，其實什麼都沒改", name: nil)]
        $0.question = t
    }
    add("28-card-onboarding", .card, stack: []) { $0.onboarding = true }

    // 畫圖題
    let smile = [Stroke(c: 4, w: 2, p: [500, 100, 700, 160, 800, 350, 700, 540, 500, 600, 300, 540, 200, 350, 300, 160, 500, 100]),
                 Stroke(c: 0, w: 2, p: [400, 290]), Stroke(c: 0, w: 2, p: [600, 290]),
                 Stroke(c: 1, w: 1, p: [380, 420, 440, 480, 500, 500, 560, 480, 620, 420])]
    let zigzag = [Stroke(c: 2, w: 1, p: [100, 500, 250, 200, 400, 500, 550, 200, 700, 500, 850, 200]),
                  Stroke(c: 3, w: 2, p: [150, 600, 850, 600])]
    let storm = [Stroke(c: 5, w: 2, p: [250, 300, 350, 200, 500, 180, 650, 200, 750, 300, 650, 380, 350, 380, 250, 300]),
                 Stroke(c: 4, w: 1, p: [520, 400, 440, 520, 520, 520, 460, 640])]
    add("30-card-draw", .card, stack: []) {
        $0.question = q(20, "用畫的：你現在的心情", author: "美玲", kind: "draw", options: [], answered: 2)
        $0.strokes = smile; $0.penColor = 1
    }
    add("31-card-draw-empty", .card, stack: []) {
        $0.question = q(20, "畫一隻貓", author: "阿凱", kind: "draw", options: [], anonymous: false, live: true, answered: 0)
        $0.agentName = "Claude Code"
    }
    add("32-card-draw-result", .card, stack: []) {
        var d = q(21, "用畫的：你現在的心情", author: "美玲", kind: "draw", options: [], anonymous: false, answered: 3, closed: true)
        d.myAnswered = true
        d.drawings = [Drawing(strokes: smile, name: "derreck"), Drawing(strokes: zigzag, name: "阿凱"),
                      Drawing(strokes: storm, name: "小林")]
        $0.question = d; $0.phase = .done
    }
    add("33-ask-draw", .ask) { apply($0, AskTemplate.all[7]) }
    // 出題者自己還沒回答的即時題：要看得到畫布，別人的畫放在下面
    add("34-question-mine-draw-unanswered", .question) {
        var d = q(22, "畫一隻貓", author: "derreck", mine: true, kind: "draw", options: [], anonymous: false, live: true, answered: 1)
        d.myAnswered = false
        d.drawings = [Drawing(strokes: zigzag, name: "阿凱")]
        $0.question = d
    }
    add("35-question-mine-choice-unanswered", .question) {
        var c = q(23, "下午要不要訂飲料？", author: "derreck", mine: true, options: ["要", "不要"], anonymous: false, live: true,
                  answered: 0, results: [0, 0])
        c.myAnswered = false; c.voters = [[], []]
        $0.question = c
    }

    MainActor.assumeIsolated {
        for (name, m) in cases {
            let view = PanelView(m: m).padding(24)
                .background(dark ? Color(white: 0.12) : Color(white: 0.9))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
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
