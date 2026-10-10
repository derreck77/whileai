// WhileAI：等 AI Agent 工作的空檔，和朋友互相出題
//
// 執行模式：
//   WhileAI                       選單列 App（常駐）
//   WhileAI hook [codex|claude-code]
//                                 給 Codex／Claude Code hooks 呼叫：讀 stdin，只轉送事件名稱給常駐 App 後立即結束
//   WhileAI snapshot <dir>        開發用：把小框框的各個畫面渲染成 PNG
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
    let now = Date().timeIntervalSince1970
    func q(_ id: Int, _ text: String, author: String = "小林", myVote: Int? = nil, closed: Bool = false,
           results: [Int]? = nil, hidden: String? = nil, answered: Int = 3) -> Question {
        Question(id: id, groupId: 1, groupName: "後端組", authorName: author, isMine: false, text: text,
                 options: ["要", "不要", "先試一週再說"], closesAt: now + 5 * 3600, closed: closed,
                 answeredCount: answered, memberCount: 8, myVote: myVote, results: results, hiddenReason: hidden)
    }
    let pending = [q(1, "下個 sprint 要不要統一改用 Codex？"), q(2, "Agent 寫的測試你會直接 merge 嗎？", author: "阿凱")]
    let result = q(3, "要不要把 lint 交給 Agent 自動修？", myVote: 2, closed: true, results: [2, 1, 5], answered: 8)
    let groups = [Group(id: 1, name: "後端組", inviteCode: "K7P3QX9M", inviteUrl: "https://x/j/K7P3QX9M", memberCount: 8, muted: false),
                  Group(id: 2, name: "大學同學", inviteCode: "M2RT8WQA", inviteUrl: "https://x/j/M2RT8WQA", memberCount: 5, muted: true)]
    let me = Me(user: UserInfo(id: 1, name: "derreck"), groups: groups)
    let detail = GroupDetail(group: groups[0], questions: pending + [q(4, "週五 demo 要用哪個 Agent 現場寫？", myVote: 1), result])

    func model(_ screen: Screen, stack: [Screen] = [.home]) -> Model {
        let m = Model()
        m.screen = screen
        m.stack = stack
        m.me = me
        m.feed = Feed(pending: pending, results: [result])
        m.unseenResults = [result]
        m.details = [1: detail]
        return m
    }
    var cases: [(String, Model)] = []
    cases.append(("01-welcome", { let m = model(.welcome, stack: []); m.nickname = "derreck"; return m }()))
    cases.append(("02-home", model(.home, stack: [])))
    cases.append(("03-group", model(.group(1))))
    cases.append(("04-create", { let m = model(.createGroup); m.groupName = "週末黑客松"; return m }()))
    cases.append(("05-join", { let m = model(.join); m.joinCode = "K7P3QX9M"; return m }()))
    cases.append(("06-ask", { let m = model(.ask(1), stack: [.home, .group(1)])
        m.askText = "Agent 寫的 PR，你會要求它附測試嗎？"; m.askOptions = ["一定要", "看情況", "不用"]; return m }()))
    cases.append(("07-question", { let m = model(.question, stack: [.home]); m.question = pending[0]; return m }()))
    cases.append(("08-card-ask", { let m = model(.card, stack: []); m.question = pending[0]; return m }()))
    cases.append(("09-card-result", { let m = model(.card, stack: []); m.question = result; m.phase = .done
        m.agentName = "Claude Code"; return m }()))
    cases.append(("10-card-onboarding", { let m = model(.card, stack: []); m.onboarding = true; return m }()))
    cases.append(("11-settings", { let m = model(.settings); m.nickname = "derreck"
        m.serverLabel = "whileai-production.up.railway.app"; return m }()))
    cases.append(("12-connect", model(.connect, stack: [])))

    MainActor.assumeIsolated {
        for (name, m) in cases {
            let r = ImageRenderer(content: PanelView(m: m).padding(20).background(Color(white: 0.9)))
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
