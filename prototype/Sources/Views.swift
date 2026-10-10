// 小框框（面板）的所有畫面：Agent 工作時自動跳出的卡片，以及點選單列 ⏳ 打開的首頁、群組、出題、設定
import AppKit
import SwiftUI

enum Screen: Equatable {
    case card               // Agent 工作時自動跳出：題目、開獎或引導
    case welcome            // 設定暱稱
    case connect            // 連接 Codex 與 Claude Code（打包版）
    case moveApp            // 請先移到「應用程式」資料夾
    case home
    case group(Int)
    case createGroup
    case join
    case ask                // 出題；發到哪個群組看 Model.askGroupId
    case question
    case settings
}

enum Phase { case working, done }

// 面板上的操作，由 AppDelegate 實作
protocol PanelActions: AnyObject {
    func go(_ screen: Screen)
    func back()
    func closePanel()
    func skipCard()
    func vote(_ answer: Any)          // 單選／評分：Int；多選：[Int]；文字：String
    func showNextPending()
    func openQuestion(_ q: Question)
    func closeEarly()
    func withdraw()
    func submitNickname()
    func saveNickname()
    func createGroup()
    func joinGroup()
    func pasteInvite()
    func startAsk(groupId: Int?)
    func selectAskGroup(_ id: Int)
    func applyTemplate(_ t: AskTemplate)
    func askQuestion()
    func toggleMute(groupId: Int)
    func copyInvite(_ g: Group)
    func togglePause()
    func connectAgents()
    func quit()
}

final class Model: ObservableObject {
    weak var actions: PanelActions?
    var preview = false                        // 快照模式：輸入框改用文字繪製

    @Published var screen: Screen = .home
    @Published var stack: [Screen] = []
    @Published var phase: Phase = .working
    @Published var agentName = "Codex"
    @Published var onboarding = false          // 自動卡片顯示的是引導（還沒加入群組）
    @Published var question: Question?
    @Published var remaining = 0               // 這題之外還有幾題待答
    @Published var confirmWithdraw = false

    @Published var me: Me?
    @Published var feed = Feed(pending: [], results: [])
    @Published var unseenResults: [Question] = []
    @Published var details: [Int: GroupDetail] = [:]

    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var paused = false
    @Published var copiedGroup: Int?
    @Published var canConnectAgents = false
    @Published var connecting = false
    var serverLabel = ""

    // 表單
    @Published var nickname = ""
    @Published var groupName = ""
    @Published var joinCode = ""
    @Published var askGroupId: Int?
    @Published var askTemplate = "custom"
    @Published var askKind = "choice"
    @Published var askText = ""
    @Published var askOptions = ["", ""]
    @Published var askAnonymous = true
    @Published var askLive = false
    @Published var askHours: Double = 24
    @Published var askLow = ""
    @Published var askHigh = ""
    @Published var askShowSettings = false

    // 回答多選題、文字題、畫圖題時的暫存
    @Published var multiSelection = Set<Int>()
    @Published var answerText = ""
    @Published var strokes: [Stroke] = []
    @Published var penColor = 0
    @Published var penWidth = 1
    var strokeOpen = false                     // 目前有一筆正在畫（滑鼠還沒放開）
    var pointCount: Int { strokes.reduce(0) { $0 + $1.p.count / 2 } }

    var groups: [Group] { me?.groups ?? [] }
    var askGroup: Group? { groups.first { $0.id == askGroupId } }

    var title: String {
        switch screen {
        case .card: return ""
        case .welcome: return "歡迎"
        case .connect: return "連接 Agent"
        case .moveApp: return "還差一步"
        case .home: return "WhileAI"
        case .group(let id): return details[id]?.group.name ?? groups.first { $0.id == id }?.name ?? "群組"
        case .createGroup: return "建立群組"
        case .join: return "加入群組"
        case .ask: return "出題"
        case .question: return question?.groupName ?? "題目"
        case .settings: return "設定"
        }
    }
}

// MARK: - 設計元件

enum Theme {
    static let width: CGFloat = 352
    static let pad: CGFloat = 16
    static let radius: CGFloat = 16
    static let named = Color.orange
    static func fill(_ strength: Double = 0.06) -> Color { Color.primary.opacity(strength) }
}

/// 主要按鈕：實心、整排寬
struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var full = true
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon = icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: full ? .infinity : nil)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(enabled ? (hover ? 0.88 : 1) : 0.35)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

/// 次要按鈕：淡底
struct SoftButton: View {
    let title: String
    var icon: String? = nil
    var full = false
    var tint: Color = .primary
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon = icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 12)
            .frame(maxWidth: full ? .infinity : nil)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(hover && enabled ? 0.14 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.fill(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

/// 文字輸入框。快照模式下改畫成文字，才能檢查排版
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var multiline = false
    var preview = false
    var onSubmit: () -> Void = {}

    var body: some View {
        SwiftUI.Group {
            if preview {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? HierarchicalShapeStyle.tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if multiline {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .onSubmit(onSubmit)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit(onSubmit)
            }
        }
        .font(mono ? .system(size: 15, weight: .medium, design: .monospaced) : .system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fill()))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.fill(0.08)))
    }
}

/// 分段選擇
struct Segmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let on = items[i].0 == selection
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { selection = items[i].0 } }) {
                    Text(items[i].1)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(on ? Color.white.opacity(scheme == .dark ? 0.18 : 0.95) : Color.clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1.5, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill(0.08)))
    }
}

struct Pill: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon = icon { Image(systemName: icon).font(.system(size: 8.5, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

struct SectionLabel: View {
    let text: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let count = count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

struct Row: View {
    var icon: String? = nil
    var iconTint: Color = .secondary
    let title: String
    var subtitle: String? = nil
    var accent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(iconTint)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(iconTint.opacity(0.13)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill(hover ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

struct Hint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 列表最多顯示的高度，超過就捲動
struct CappedList<Content: View>: View {
    let count: Int
    let rowHeight: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if CGFloat(count) * rowHeight > maxHeight {
            ScrollView { VStack(spacing: 6) { content() } }.frame(height: maxHeight)
        } else {
            VStack(spacing: 6) { content() }
        }
    }
}

struct PulseDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true } }
    }
}

struct Banner: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.12)))
    }
}

// MARK: - 外框

struct PanelView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = m.notice, m.screen != .card {
                Banner(text: notice, icon: "checkmark.circle.fill", tint: .green)
            }
            content
            if let err = m.error {
                Banner(text: err, icon: "exclamationmark.triangle.fill", tint: .red)
            }
        }
        .padding(Theme.pad)
        .frame(width: Theme.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Color.primary.opacity(0.1)))
    }

    @ViewBuilder var header: some View {
        if m.screen == .card {
            HStack(spacing: 6) {
                if m.phase == .done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                    Text("\(m.agentName) 完成了，回去看看吧")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    PulseDot(color: .accentColor)
                    Text("\(m.agentName) 工作中")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(symbol: "xmark", help: "略過") { m.actions?.skipCard() }
            }
        } else {
            HStack(spacing: 4) {
                if !m.stack.isEmpty {
                    IconButton(symbol: "chevron.left", help: "返回") { m.actions?.back() }
                } else if m.screen == .home {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                }
                Text(m.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if m.busy { ProgressView().controlSize(.small).padding(.trailing, 2) }
                if m.screen == .home {
                    IconButton(symbol: "gearshape", help: "設定") { m.actions?.go(.settings) }
                }
                IconButton(symbol: "xmark", help: "關閉") { m.actions?.closePanel() }
            }
        }
    }

    @ViewBuilder var content: some View {
        switch m.screen {
        case .card:
            if m.onboarding { OnboardingCard(m: m) } else if let q = m.question { QuestionView(m: m, q: q) }
        case .welcome: WelcomeView(m: m)
        case .connect: ConnectView(m: m)
        case .moveApp: MoveAppView()
        case .home: HomeView(m: m)
        case .group(let id): GroupView(m: m, id: id)
        case .createGroup: CreateGroupView(m: m)
        case .join: JoinView(m: m)
        case .ask: AskView(m: m)
        case .question: if let q = m.question { QuestionView(m: m, q: q) }
        case .settings: SettingsView(m: m)
        }
    }
}

// MARK: - 第一次使用

struct WelcomeView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("等 Agent 的空檔，\n和朋友互相出題。")
                    .font(.system(size: 19, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Hint(text: "午餐吃什麼、要不要換工具、今天 Agent 做了什麼蠢事。題目會在大家等 Codex 或 Claude Code 時自己出現。")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("你的暱稱").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Field(placeholder: "朋友會看到這個名字", text: $m.nickname, preview: m.preview) { m.actions?.submitNickname() }
            }
            PrimaryButton(title: "開始") { m.actions?.submitNickname() }
                .disabled(m.nickname.trimmingCharacters(in: .whitespaces).isEmpty || m.busy)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct ConnectView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WhileAI 需要知道 Codex 和 Claude Code 什麼時候開始、什麼時候完成，才能在等待時送出題目。")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Hint(text: "會修改 ~/.codex/hooks.json、~/.codex/config.toml 與 ~/.claude/settings.json，修改前會先備份。WhileAI 只接收「開始／完成」事件，不會讀取你的程式碼或 prompt。")
            HStack(spacing: 8) {
                PrimaryButton(title: m.connecting ? "連接中…" : "連接") { m.actions?.connectAgents() }
                SoftButton(title: "稍後") { m.actions?.go(.welcome) }
            }
            .disabled(m.connecting)
        }
    }
}

struct MoveAppView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("請先把 WhileAI 移到「應用程式」資料夾")
                .font(.system(size: 13, weight: .semibold))
            Hint(text: "從「下載」把 WhileAI 拖到「應用程式」，再重新打開。這樣 Codex 和 Claude Code 才找得到它。")
        }
    }
}

// MARK: - 首頁

struct HomeView: View {
    @ObservedObject var m: Model

    var body: some View {
        if m.groups.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 8) {
                PrimaryButton(title: "出題", icon: "plus") { m.actions?.startAsk(groupId: nil) }

                if !m.feed.pending.isEmpty {
                    SectionLabel(text: "待你回答", count: m.feed.pending.count)
                    CappedList(count: m.feed.pending.count, rowHeight: 50, maxHeight: 156) {
                        ForEach(m.feed.pending) { q in
                            Row(icon: q.kindSymbol, iconTint: .accentColor, title: q.text,
                                subtitle: "\(q.groupName) · \(q.authorName) · \(timeLeft(q.closesAt))", accent: true) {
                                m.actions?.openQuestion(q)
                            }
                        }
                    }
                }
                if !m.unseenResults.isEmpty {
                    SectionLabel(text: "新開獎")
                    ForEach(m.unseenResults.prefix(3)) { q in
                        Row(icon: "party.popper", iconTint: .pink, title: q.text,
                            subtitle: "\(q.groupName) · \(q.answeredCount) 人回答") { m.actions?.openQuestion(q) }
                    }
                }
                let mine = (m.feed.mine ?? []).filter { q in !m.feed.pending.contains { $0.id == q.id } }
                if !mine.isEmpty {
                    SectionLabel(text: "我出的題")
                    ForEach(mine.prefix(3)) { q in
                        Row(icon: q.kindSymbol, title: q.text,
                            subtitle: "\(q.answeredCount)／\(q.memberCount) 人已答 · \(timeLeft(q.closesAt))") {
                            m.actions?.openQuestion(q)
                        }
                    }
                }
                if m.feed.pending.isEmpty && m.unseenResults.isEmpty && mine.isEmpty {
                    Hint(text: "目前沒有待答題。出一題，或等朋友的題目在 Agent 工作時跳出來。")
                        .padding(.vertical, 2)
                }

                HStack {
                    SectionLabel(text: "群組")
                    LinkButton(title: "建立") { m.actions?.go(.createGroup) }
                    Text("·").foregroundStyle(.tertiary).font(.system(size: 11))
                    LinkButton(title: "加入") { m.actions?.go(.join) }
                }
                CappedList(count: m.groups.count, rowHeight: 50, maxHeight: 150) {
                    ForEach(m.groups) { g in
                        Row(icon: g.muted ? "bell.slash" : "person.2", title: g.name,
                            subtitle: "\(g.memberCount) 人\(g.muted ? " · 靜音中" : "")") {
                            m.actions?.go(.group(g.id))
                        }
                    }
                }

                Divider().padding(.top, 2)
                HStack {
                    Button(action: { m.actions?.togglePause() }) {
                        HStack(spacing: 4) {
                            Image(systemName: m.paused ? "play.fill" : "pause.fill").font(.system(size: 8))
                            Text(m.paused ? "已暫停 · 點此恢復" : "暫停 1 小時").font(.system(size: 11))
                        }
                        .foregroundStyle(m.paused ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(m.me?.user.name ?? "").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // 還沒有群組：直接給兩條路
    var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("嗨，\(m.me?.user.name ?? "")").font(.system(size: 19, weight: .bold))
                Hint(text: "先找到你的朋友。建立一個群組，或加入朋友已經建好的。")
            }
            BigChoice(icon: "person.2.badge.plus", title: "建立群組", subtitle: "拿到邀請碼，傳給朋友") {
                m.actions?.go(.createGroup)
            }
            BigChoice(icon: "ticket", title: "我有邀請碼", subtitle: "貼上朋友傳給你的邀請") {
                m.actions?.go(.join)
            }
        }
    }
}

struct BigChoice: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill(hover ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

// MARK: - 群組

struct GroupView: View {
    @ObservedObject var m: Model
    let id: Int

    var body: some View {
        if let d = m.details[id] {
            VStack(alignment: .leading, spacing: 10) {
                // 邀請
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("邀請碼 · \(d.group.memberCount) 位成員")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(d.group.inviteCode)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    SoftButton(title: m.copiedGroup == id ? "已複製" : "複製邀請",
                               icon: m.copiedGroup == id ? "checkmark" : "doc.on.doc",
                               tint: m.copiedGroup == id ? .green : .accentColor) { m.actions?.copyInvite(d.group) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.09)))

                if d.group.memberCount < 3 {
                    Hint(text: d.group.memberCount == 1 ? "現在只有你一個人。把邀請貼給朋友，他們加入後就能一起玩。"
                                                         : "群組有 2 人。匿名題要滿 3 人回答才會顯示結果，人少時建議用具名題。")
                }

                HStack(spacing: 8) {
                    PrimaryButton(title: "出題", icon: "plus") { m.actions?.startAsk(groupId: id) }
                    SoftButton(title: d.group.muted ? "取消靜音" : "靜音", icon: d.group.muted ? "bell" : "bell.slash") {
                        m.actions?.toggleMute(groupId: id)
                    }
                }

                SectionLabel(text: "題目")
                if d.questions.isEmpty {
                    Hint(text: "還沒有題目，出第一題吧。")
                } else {
                    CappedList(count: d.questions.count, rowHeight: 50, maxHeight: 208) {
                        ForEach(d.questions) { q in
                            let waiting = !q.closed && !q.answered
                            Row(icon: q.closed ? "checkmark.seal" : q.kindSymbol,
                                iconTint: waiting ? .accentColor : .secondary,
                                title: q.text, subtitle: status(q), accent: waiting) {
                                m.actions?.openQuestion(q)
                            }
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Hint(text: "載入中…") }
                .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    func status(_ q: Question) -> String {
        if q.closed { return q.hasResults ? "已開獎 · \(q.answeredCount) 人回答" : "已截止 · 回答不足 3 人" }
        if !q.answered { return "待你回答 · \(q.authorName) · \(timeLeft(q.closesAt))" }
        return "已回答 · \(q.answeredCount)／\(q.memberCount) · \(timeLeft(q.closesAt))"
    }
}

struct CreateGroupView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(placeholder: "群組名稱，例如：後端組、午餐團", text: $m.groupName, preview: m.preview) { m.actions?.createGroup() }
            Hint(text: "建立後會拿到一組邀請碼，傳給朋友就能加入。")
            PrimaryButton(title: "建立") { m.actions?.createGroup() }
                .disabled(m.groupName.trimmingCharacters(in: .whitespaces).isEmpty || m.busy)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct JoinView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrimaryButton(title: "貼上邀請", icon: "doc.on.clipboard") { m.actions?.pasteInvite() }
                .disabled(m.busy)
            Hint(text: "複製朋友傳來的整段邀請訊息或連結，按一下就加入。")
            HStack {
                Rectangle().fill(Theme.fill(0.1)).frame(height: 1)
                Text("或手動輸入").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize()
                Rectangle().fill(Theme.fill(0.1)).frame(height: 1)
            }
            HStack(spacing: 8) {
                Field(placeholder: "邀請碼", text: $m.joinCode, mono: true, preview: m.preview) { m.actions?.joinGroup() }
                SoftButton(title: "加入") { m.actions?.joinGroup() }
                    .disabled(extractInviteCode(m.joinCode) == nil || m.busy)
            }
        }
    }
}

// MARK: - 出題

struct AskView: View {
    @ObservedObject var m: Model
    @FocusState private var focus: Int?     // 0 = 問題；1... = 第幾個選項

    var hasOptions: Bool { m.askKind == "choice" || m.askKind == "multi" }
    var smallGroup: Bool { (m.askGroup?.memberCount ?? 3) < 3 }

    var valid: Bool {
        guard m.askGroupId != nil, m.askText.trimmingCharacters(in: .whitespaces).count >= 2 else { return false }
        guard hasOptions else { return true }
        let opts = m.askOptions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return opts.count >= 2 && Set(opts).count == opts.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 發到哪個群組（只有一個群組時不用選）
            if m.groups.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("發到").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(m.groups) { g in
                            chip(g.name, on: m.askGroupId == g.id) { m.actions?.selectAskGroup(g.id) }
                        }
                    }
                }
            }

            // 情境範本：點一下帶入設定，內容都可以再改
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(AskTemplate.all) { t in
                    Button(action: { m.actions?.applyTemplate(t); focus = 0 }) {
                        VStack(spacing: 2) {
                            Text(t.symbol).font(.system(size: 16))
                            Text(t.name).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(m.askTemplate == t.id ? Color.accentColor.opacity(0.18) : Theme.fill()))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .stroke(m.askTemplate == t.id ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
            }

            Field(placeholder: "想問大家什麼？", text: $m.askText, multiline: true, preview: m.preview)
                .focused($focus, equals: 0)

            if hasOptions {
                VStack(spacing: 6) {
                    ForEach(m.askOptions.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            Field(placeholder: "選項 \(i + 1)", text: option(i), preview: m.preview) { nextOption(after: i) }
                                .focused($focus, equals: i + 1)
                            if m.askOptions.count > 2 {
                                IconButton(symbol: "minus", help: "刪除選項") {
                                    if m.askOptions.indices.contains(i) { m.askOptions.remove(at: i) }
                                }
                            }
                        }
                    }
                    if m.askOptions.count < 6 {
                        HStack {
                            LinkButton(title: "＋ 新增選項") { m.askOptions.append(""); focus = m.askOptions.count }
                            Text("或在選項按 Enter").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                    }
                }
            } else if m.askKind == "scale" {
                HStack(spacing: 6) {
                    Field(placeholder: "1 分代表…", text: $m.askLow, preview: m.preview)
                    Field(placeholder: "5 分代表…", text: $m.askHigh, preview: m.preview)
                }
            } else if m.askKind == "draw" {
                Hint(text: "成員用滑鼠在小畫布上畫圖回答，開獎時會看到所有人的畫。")
            } else {
                Hint(text: "成員用一句話回答，最多 140 字。")
            }

            settings

            if smallGroup && m.askAnonymous {
                Banner(text: "這個群組只有 \(m.askGroup?.memberCount ?? 1) 人。匿名題要滿 3 人回答才會顯示結果，建議改成具名。",
                       icon: "exclamationmark.circle.fill", tint: .orange)
            }

            PrimaryButton(title: "發問") { m.actions?.askQuestion() }
                .disabled(!valid || m.busy)
        }
    }

    // 設定摘要，點了才展開
    @ViewBuilder var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeOut(duration: 0.16)) { m.askShowSettings.toggle() } }) {
                HStack(spacing: 4) {
                    Pill(text: kindLabel)
                    Pill(text: m.askAnonymous ? "匿名" : "具名", icon: m.askAnonymous ? "lock.fill" : "person.fill",
                         tint: m.askAnonymous ? .secondary : Theme.named)
                    Pill(text: m.askLive ? "立刻看結果" : "截止才開獎", icon: m.askLive ? "bolt.fill" : nil)
                    Pill(text: deadlineLabel, icon: "clock")
                    Spacer(minLength: 2)
                    Image(systemName: m.askShowSettings ? "chevron.up" : "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("調整題型、匿名、開獎時機與截止時間")

            if m.askShowSettings {
                VStack(spacing: 6) {
                    Segmented(items: [("choice", "單選"), ("multi", "多選"), ("scale", "評分"), ("text", "文字"), ("draw", "畫圖")],
                              selection: $m.askKind)
                    Segmented(items: [(true, "匿名"), (false, "具名")], selection: $m.askAnonymous)
                    Segmented(items: [(false, "截止才開獎"), (true, "回答後立刻看結果")], selection: $m.askLive)
                    Segmented(items: [(0.5, "30 分"), (1.0, "1 小時"), (4.0, "4 小時"), (24.0, "1 天"), (72.0, "3 天")],
                              selection: $m.askHours)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill(0.04)))
    }

    var kindLabel: String {
        ["choice": "單選", "multi": "多選", "scale": "評分", "text": "文字", "draw": "畫圖"][m.askKind] ?? "單選"
    }

    var deadlineLabel: String {
        m.askHours < 1 ? "\(Int(m.askHours * 60)) 分" : m.askHours < 24 ? "\(Int(m.askHours)) 小時" : "\(Int(m.askHours / 24)) 天"
    }

    func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.16) : Theme.fill()))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 在選項按 Enter：跳到下一個選項；已經是最後一個就新增一個
    func nextOption(after i: Int) {
        if i + 1 < m.askOptions.count {
            focus = i + 2
        } else if m.askOptions.count < 6 && !(m.askOptions[safe: i] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            m.askOptions.append("")
            focus = m.askOptions.count
        }
    }

    // 刪除選項時，避免 SwiftUI 用舊的索引讀取而越界
    func option(_ i: Int) -> Binding<String> {
        Binding(get: { m.askOptions[safe: i] ?? "" },
                set: { if m.askOptions.indices.contains(i) { m.askOptions[i] = $0 } })
    }
}

// MARK: - 題目與開獎

struct QuestionView: View {
    @ObservedObject var m: Model
    let q: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(m.screen == .card ? "\(q.groupName) · \(q.authorName)" : "\(q.authorName) 出題")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if q.closed { Pill(text: "已開獎", icon: "party.popper.fill", tint: .pink) }
                    Pill(text: q.isAnonymous ? "匿名" : "具名", icon: q.isAnonymous ? "lock.fill" : "person.fill",
                         tint: q.isAnonymous ? .secondary : Theme.named)
                }
                Text(q.text)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if q.hasResults {
                ResultsView(q: q)
            } else if q.closed {
                Banner(text: q.hiddenReason ?? "結果未公開", icon: "lock.fill", tint: .secondary)
            } else if q.answered {
                Banner(text: "已回答 · \(q.hiddenReason ?? "開獎時會通知你")", icon: "checkmark.circle.fill", tint: .green)
            } else {
                answerUI
                if !q.isAnonymous {
                    Text("具名題：大家會看到你的回答").font(.system(size: 10.5)).foregroundStyle(Theme.named)
                }
            }

            footer
        }
    }

    @ViewBuilder var footer: some View {
        HStack(spacing: 6) {
            Text(q.closed ? "\(q.answeredCount)／\(q.memberCount) 人回答"
                          : "\(q.answeredCount)／\(q.memberCount) 人已答 · \(timeLeft(q.closesAt))")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
            if !q.closed && q.isLive && !q.answered {
                Text("· 回答後立刻看結果").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        // 答完還有其他待答題：想繼續的人可以接著答
        if (q.answered || q.closed) && m.remaining > 0 {
            SoftButton(title: "下一題（還有 \(m.remaining) 題）", icon: "arrow.right", full: true, tint: .accentColor) {
                m.actions?.showNextPending()
            }
        }
        // 出題者：提前開獎、撤回
        if q.isMine && !q.closed && m.screen != .card {
            HStack(spacing: 8) {
                SoftButton(title: "提前開獎", icon: "flag.checkered", full: true) { m.actions?.closeEarly() }
                SoftButton(title: m.confirmWithdraw ? "確定撤回？" : "撤回", icon: "trash", full: true,
                           tint: m.confirmWithdraw ? .red : .primary) { m.actions?.withdraw() }
            }
            .disabled(m.busy)
        }
    }

    // MARK: 回答

    @ViewBuilder var answerUI: some View {
        switch q.qKind {
        case "multi":
            VStack(spacing: 6) {
                ForEach(q.options.indices, id: \.self) { i in
                    OptionButton(text: q.options[i], check: m.multiSelection.contains(i) ? .on : .off) {
                        if m.multiSelection.contains(i) { m.multiSelection.remove(i) } else { m.multiSelection.insert(i) }
                    }
                }
                PrimaryButton(title: m.multiSelection.isEmpty ? "選好後送出" : "送出 \(m.multiSelection.count) 個選擇") {
                    m.actions?.vote(Array(m.multiSelection).sorted())
                }
                .disabled(m.multiSelection.isEmpty || m.busy)
            }
        case "scale":
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { i in ScaleButton(n: i + 1) { m.actions?.vote(i) } }
                }
                .disabled(m.busy)
                ScaleLabels(q: q)
            }
        case "draw":
            DrawingPad(m: m)
        case "text":
            VStack(alignment: .trailing, spacing: 6) {
                Field(placeholder: "寫下你的回答…", text: $m.answerText, multiline: true, preview: m.preview)
                HStack {
                    Text("\(m.answerText.count)／140")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(m.answerText.count > 140 ? Color.red : Color.secondary.opacity(0.7))
                    Spacer()
                    PrimaryButton(title: "送出", full: false) {
                        m.actions?.vote(m.answerText.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(m.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || m.answerText.count > 140 || m.busy)
                }
            }
        default:
            VStack(spacing: 6) {
                ForEach(q.options.indices, id: \.self) { i in
                    OptionButton(text: q.options[i]) { m.actions?.vote(i) }
                }
            }
            .disabled(m.busy)
        }
    }
}

struct OptionButton: View {
    enum Check { case none, off, on }
    let text: String
    var check: Check = .none
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if check != .none {
                    Image(systemName: check == .on ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(check == .on ? Color.accentColor : Color.secondary)
                }
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(check == .on ? Color.accentColor.opacity(0.16) : Theme.fill(hover ? 0.13 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(hover || check == .on ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

struct ScaleButton: View {
    let n: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text("\(n)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(hover ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Color.accentColor : Theme.fill(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

struct ScaleLabels: View {
    let q: Question
    var body: some View {
        if q.scaleLow != nil || q.scaleHigh != nil {
            HStack {
                Text(q.scaleLow.map { "1 · \($0)" } ?? "")
                Spacer()
                Text(q.scaleHigh.map { "\($0) · 5" } ?? "")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }
}

struct ResultsView: View {
    let q: Question
    @State private var shown = false     // 長條從 0 長出來

    var body: some View {
        if let drawings = q.drawings {
            DrawingGallery(drawings: drawings)
        } else if let texts = q.texts {
            CappedList(count: texts.count, rowHeight: 46, maxHeight: 216) {
                ForEach(texts.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "quote.opening").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(texts[i].text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            if let name = texts[i].name {
                                Text(name).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fill(0.05)))
                }
            }
        } else if let counts = q.results {
            // 多選題的百分比以「回答人數」為分母；其他題型以總票數為分母
            let votes = counts.reduce(0, +)
            let total = max(q.qKind == "multi" ? q.answeredCount : votes, 1)
            let top = counts.max() ?? 0
            VStack(alignment: .leading, spacing: 8) {
                if q.qKind == "scale" {
                    let sum = counts.enumerated().reduce(0) { $0 + ($1.offset + 1) * $1.element }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", Double(sum) / Double(max(votes, 1))))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("／5 平均").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ScaleLabels(q: q)
                }
                ForEach(q.options.indices, id: \.self) { i in
                    let n = counts[safe: i] ?? 0
                    let pct = Double(n) / Double(total)
                    let mine = q.isMyChoice(i)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(q.qKind == "scale" ? "\(i + 1) 分" : q.options[i])
                                .font(.system(size: 12, weight: n == top && n > 0 ? .semibold : .regular))
                            if mine { Pill(text: "你", tint: .accentColor) }
                            Spacer()
                            Text("\(n) 票").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                            Text("\(Int((pct * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.fill(0.08))
                                Capsule().fill(mine ? Color.accentColor : Color.secondary.opacity(0.55))
                                    .frame(width: max(g.size.width * min(pct, 1) * (shown ? 1 : 0), n > 0 && shown ? 6 : 0))
                            }
                        }
                        .frame(height: 6)
                        if let names = q.voters?[safe: i], !names.isEmpty {
                            Text(names.joined(separator: "、"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { shown = true } }
        }
    }
}

// MARK: - 畫圖題

enum Palette {
    /// 畫布固定是白底，所以用固定的顏色，不跟著深色模式變
    static let colors: [Color] = [
        Color(red: 0.11, green: 0.11, blue: 0.12),   // 墨黑
        Color(red: 0.90, green: 0.22, blue: 0.21),   // 紅
        Color(red: 0.13, green: 0.47, blue: 0.95),   // 藍
        Color(red: 0.18, green: 0.66, blue: 0.36),   // 綠
        Color(red: 0.98, green: 0.60, blue: 0.09),   // 橘
        Color(red: 0.58, green: 0.34, blue: 0.86),   // 紫
    ]
    static let paper = Color.white
    static func color(_ i: Int) -> Color { colors[safe: i] ?? colors[0] }
}

/// 把筆畫畫出來（唯讀）。畫布比例固定 10:7
struct DrawingView: View {
    let strokes: [Stroke]
    var corner: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / Stroke.canvasSize.width
            let sy = size.height / Stroke.canvasSize.height
            for s in strokes {
                var pts: [CGPoint] = []
                var i = 0
                while i + 1 < s.p.count {
                    pts.append(CGPoint(x: CGFloat(s.p[i]) * sx, y: CGFloat(s.p[i + 1]) * sy))
                    i += 2
                }
                guard let first = pts.first else { continue }
                var path = Path()
                path.move(to: first)
                if pts.count == 1 {
                    path.addLine(to: first)     // 單點：靠圓頭線帽畫成一個點
                } else {
                    // 經過相鄰兩點的中點畫二次曲線，線條比直接連線圓滑
                    for k in 1..<pts.count {
                        let mid = CGPoint(x: (pts[k - 1].x + pts[k].x) / 2, y: (pts[k - 1].y + pts[k].y) / 2)
                        path.addQuadCurve(to: mid, control: pts[k - 1])
                    }
                    path.addLine(to: pts[pts.count - 1])
                }
                ctx.stroke(path, with: .color(Palette.color(s.c)),
                           style: StrokeStyle(lineWidth: (s.w == 2 ? 0.024 : 0.009) * size.width,
                                              lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(Stroke.canvasSize.width / Stroke.canvasSize.height, contentMode: .fit)
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).stroke(Color.primary.opacity(0.12)))
    }
}

/// 作畫區：畫布＋工具列（顏色、粗細、復原、清除）＋送出
struct DrawingPad: View {
    @ObservedObject var m: Model

    var full: Bool { m.pointCount >= Stroke.maxPoints }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                DrawingView(strokes: m.strokes)
                    .overlay(alignment: .center) {
                        if m.strokes.isEmpty {
                            VStack(spacing: 4) {
                                Image(systemName: "scribble.variable").font(.system(size: 20))
                                Text("在這裡按住滑鼠畫圖").font(.system(size: 11.5))
                            }
                            .foregroundStyle(Color.black.opacity(0.28))
                            .fixedSize()
                            .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in add(v.location, in: geo.size) }
                        .onEnded { _ in m.strokeOpen = false })
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            }
            .aspectRatio(Stroke.canvasSize.width / Stroke.canvasSize.height, contentMode: .fit)

            HStack(spacing: 6) {
                ForEach(Palette.colors.indices, id: \.self) { i in
                    Button(action: { m.penColor = i }) {
                        Circle()
                            .fill(Palette.colors[i])
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5).padding(1))
                            .overlay(Circle().stroke(m.penColor == i ? Color.accentColor : Color.primary.opacity(0.15),
                                                     lineWidth: m.penColor == i ? 2 : 1))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("顏色")
                }
                Spacer(minLength: 2)
                widthButton(1)
                widthButton(2)
                Rectangle().fill(Theme.fill(0.12)).frame(width: 1, height: 16)
                IconButton(symbol: "arrow.uturn.backward", help: "復原上一筆") {
                    if !m.strokes.isEmpty { m.strokes.removeLast() }
                    m.strokeOpen = false
                }
                .disabled(m.strokes.isEmpty)
                IconButton(symbol: "trash", help: "清除重畫") { m.strokes = []; m.strokeOpen = false }
                    .disabled(m.strokes.isEmpty)
            }

            if full {
                Hint(text: "畫布已經畫滿了。可以復原幾筆，或直接送出。")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PrimaryButton(title: m.strokes.isEmpty ? "畫好後送出" : "送出這張畫") {
                m.actions?.vote(m.strokes.map { $0.json })
            }
            .disabled(m.strokes.isEmpty || m.busy)
        }
    }

    func widthButton(_ w: Int) -> some View {
        Button(action: { m.penWidth = w }) {
            Circle()
                .fill(Color.primary.opacity(m.penWidth == w ? 0.9 : 0.4))
                .frame(width: w == 2 ? 11 : 5, height: w == 2 ? 11 : 5)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill(m.penWidth == w ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(w == 2 ? "粗筆" : "細筆")
    }

    /// 滑鼠位置換算成 0–1000 的畫布座標，加進目前這一筆
    func add(_ location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = Int((min(max(location.x / size.width, 0), 1) * Stroke.canvasSize.width).rounded())
        let y = Int((min(max(location.y / size.height, 0), 1) * Stroke.canvasSize.height).rounded())
        if !m.strokeOpen {
            guard !full else { return }
            m.strokes.append(Stroke(c: m.penColor, w: m.penWidth, p: [x, y]))
            m.strokeOpen = true
            return
        }
        guard !full, var last = m.strokes.last, last.p.count >= 2 else { return }
        // 移動太短就不記，減少資料量
        let dx = x - last.p[last.p.count - 2], dy = y - last.p[last.p.count - 1]
        guard dx * dx + dy * dy >= 16 else { return }
        last.p.append(contentsOf: [x, y])
        m.strokes[m.strokes.count - 1] = last
    }
}

/// 開獎：所有人的畫
struct DrawingGallery: View {
    let drawings: [Drawing]

    var body: some View {
        if drawings.count == 1 {
            cell(drawings[0])
        } else {
            let grid = LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(drawings.indices, id: \.self) { i in cell(drawings[i]) }
            }
            if drawings.count > 4 {
                ScrollView { grid }.frame(height: 290)
            } else {
                grid
            }
        }
    }

    func cell(_ d: Drawing) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            DrawingView(strokes: d.strokes, corner: 8)
            if let name = d.name {
                Text(name).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct OnboardingCard: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WhileAI 已連上 \(m.agentName)")
                .font(.system(size: 16, weight: .semibold))
            Hint(text: "以後 Agent 工作時，朋友出的題目會出現在這裡。先建立一個群組，或加入朋友的群組。")
            HStack(spacing: 8) {
                PrimaryButton(title: "建立群組") { m.actions?.go(.createGroup) }
                SoftButton(title: "我有邀請碼", full: true) { m.actions?.go(.join) }
            }
        }
    }
}

// MARK: - 設定

struct SettingsView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "暱稱")
            HStack(spacing: 8) {
                Field(placeholder: "暱稱", text: $m.nickname, preview: m.preview) { m.actions?.saveNickname() }
                SoftButton(title: "儲存") { m.actions?.saveNickname() }
                    .disabled(m.nickname.trimmingCharacters(in: .whitespaces).isEmpty || m.nickname == m.me?.user.name)
            }

            SectionLabel(text: "跳出卡片")
            SoftButton(title: m.paused ? "已暫停 · 點此恢復" : "暫停 1 小時", icon: m.paused ? "play.fill" : "pause.fill",
                       full: true, tint: m.paused ? .orange : .primary) { m.actions?.togglePause() }
            Hint(text: "卡片只在 Agent 工作超過 8 秒時出現；Agent 需要你時會自動收起。")

            if m.canConnectAgents {
                SectionLabel(text: "Agent")
                SoftButton(title: "連接 Codex 與 Claude Code", icon: "link", full: true) { m.actions?.go(.connect) }
            }

            Divider().padding(.top, 2)
            HStack {
                Text(m.serverLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                SoftButton(title: "結束 WhileAI", icon: "power") { m.actions?.quit() }
            }
        }
    }
}
