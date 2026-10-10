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
    case ask(Int)
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
    func applyTemplate(_ t: AskTemplate)
    func openQuestion(_ q: Question)
    func submitNickname()
    func saveNickname()
    func createGroup()
    func joinGroup()
    func askQuestion(groupId: Int)
    func toggleMute(groupId: Int)
    func copyInvite(_ g: Group)
    func togglePause()
    func connectAgents()
    func quit()
}

final class Model: ObservableObject {
    weak var actions: PanelActions?

    @Published var screen: Screen = .home
    @Published var stack: [Screen] = []
    @Published var phase: Phase = .working
    @Published var agentName = "Codex"
    @Published var onboarding = false          // 自動卡片顯示的是引導（還沒加入群組）
    @Published var question: Question?

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
    @Published var askTemplate = "custom"
    @Published var askKind = "choice"
    @Published var askText = ""
    @Published var askOptions = ["", ""]
    @Published var askAnonymous = true
    @Published var askLive = false
    @Published var askHours: Double = 24
    @Published var askLow = ""
    @Published var askHigh = ""

    // 回答多選題、文字題時的暫存
    @Published var multiSelection = Set<Int>()
    @Published var answerText = ""

    var title: String {
        switch screen {
        case .card: return ""
        case .welcome: return "歡迎使用 WhileAI"
        case .connect: return "連接 Agent"
        case .moveApp: return "還差一步"
        case .home: return "WhileAI"
        case .group(let id): return details[id]?.group.name ?? me?.groups.first { $0.id == id }?.name ?? "群組"
        case .createGroup: return "建立群組"
        case .join: return "加入群組"
        case .ask: return "出題"
        case .question: return question?.groupName ?? "題目"
        case .settings: return "設定"
        }
    }
}

// MARK: - 外框

struct PanelView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if let err = m.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }

    @ViewBuilder var header: some View {
        if m.screen == .card {
            HStack {
                Text(m.phase == .done ? "✓ \(m.agentName) 完成了，回去看看吧" : "\(m.agentName) 工作中 · 隨時可略過")
                    .font(.caption)
                    .foregroundStyle(m.phase == .done ? Color.green : Color.secondary)
                Spacer()
                IconButton(symbol: "xmark", help: "略過") { m.actions?.skipCard() }
            }
        } else {
            HStack(spacing: 6) {
                if !m.stack.isEmpty {
                    IconButton(symbol: "chevron.left", help: "返回") { m.actions?.back() }
                }
                if m.screen == .home {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                }
                Text(m.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
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
        case .ask(let id): AskView(m: m, groupId: id)
        case .question: if let q = m.question { QuestionView(m: m, q: q) }
        case .settings: SettingsView(m: m)
        }
    }
}

// MARK: - 小元件

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

struct Row: View {
    let title: String
    var subtitle: String? = nil
    var accent: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.09 : 0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Hint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// 列表最多顯示的高度，超過就捲動
struct CappedList<Content: View>: View {
    let count: Int
    let rowHeight: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let h = CGFloat(count) * rowHeight
        if h > maxHeight {
            ScrollView { VStack(spacing: 6) { content() } }.frame(height: maxHeight)
        } else {
            VStack(spacing: 6) { content() }
        }
    }
}

// MARK: - 第一次使用

struct WelcomeView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在等 AI 的空檔，和朋友互相出題。")
                .font(.callout)
            TextField("取一個暱稱", text: $m.nickname)
                .textFieldStyle(.roundedBorder)
                .onSubmit { m.actions?.submitNickname() }
            Hint(text: "你出題時，其他人會看到這個暱稱；你的答案永遠匿名。")
            Button("開始") { m.actions?.submitNickname() }
                .buttonStyle(.borderedProminent)
                .disabled(m.nickname.trimmingCharacters(in: .whitespaces).isEmpty || m.busy)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct ConnectView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WhileAI 需要知道 Codex 和 Claude Code 什麼時候開始、什麼時候完成，才能在等待時送出題目。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Hint(text: "會修改 ~/.codex/hooks.json、~/.codex/config.toml 與 ~/.claude/settings.json，修改前會先備份。WhileAI 只接收「開始／完成」事件，不會讀取你的程式碼或 prompt。")
            if let notice = m.notice {
                Text(notice).font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(m.connecting ? "連接中…" : "連接") { m.actions?.connectAgents() }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.connecting)
                Button("稍後") { m.actions?.go(.welcome) }
                    .disabled(m.connecting)
            }
        }
    }
}

struct MoveAppView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("請先把 WhileAI 移到「應用程式」資料夾")
                .font(.callout.weight(.semibold))
            Hint(text: "從「下載」把 WhileAI 拖到「應用程式」，再重新打開。這樣 Codex 和 Claude Code 才找得到它。")
        }
    }
}

// MARK: - 首頁

struct HomeView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !m.feed.pending.isEmpty {
                SectionLabel(text: "待你回答（\(m.feed.pending.count)）")
                CappedList(count: m.feed.pending.count, rowHeight: 52, maxHeight: 170) {
                    ForEach(m.feed.pending) { q in
                        Row(title: q.text, subtitle: "\(q.groupName) · \(q.authorName) · \(timeLeft(q.closesAt))", accent: true) {
                            m.actions?.openQuestion(q)
                        }
                    }
                }
            }
            if !m.unseenResults.isEmpty {
                SectionLabel(text: "新開獎 🎉")
                ForEach(m.unseenResults.prefix(3)) { q in
                    Row(title: q.text, subtitle: "\(q.groupName) · \(q.answeredCount) 人回答") { m.actions?.openQuestion(q) }
                }
            }
            if m.feed.pending.isEmpty && m.unseenResults.isEmpty && !(m.me?.groups.isEmpty ?? true) {
                Hint(text: "目前沒有待答題。Agent 工作時，新題目會自己跳出來。")
            }

            SectionLabel(text: "我的群組")
            let groups = m.me?.groups ?? []
            if groups.isEmpty {
                Hint(text: "還沒有群組。建立一個，把邀請碼傳給朋友；或輸入朋友給你的邀請碼。")
            } else {
                CappedList(count: groups.count, rowHeight: 50, maxHeight: 160) {
                    ForEach(groups) { g in
                        Row(title: g.name, subtitle: "\(g.memberCount) 人\(g.muted ? " · 靜音中" : "")") {
                            m.actions?.go(.group(g.id))
                        }
                    }
                }
            }
            HStack {
                Button("＋ 建立群組") { m.actions?.go(.createGroup) }
                Button("輸入邀請碼") { m.actions?.go(.join) }
            }

            Divider()
            HStack {
                Button(m.paused ? "▶︎ 恢復跳出卡片" : "⏸ 暫停 1 小時") { m.actions?.togglePause() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(m.me?.user.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                IconButton(symbol: "gearshape", help: "設定") { m.actions?.go(.settings) }
            }
        }
    }
}

// MARK: - 群組

struct GroupView: View {
    @ObservedObject var m: Model
    let id: Int

    var body: some View {
        if let d = m.details[id] {
            VStack(alignment: .leading, spacing: 10) {
                Hint(text: "\(d.group.memberCount) 位成員 · 答案匿名 · ≥3 人回答才公開")

                VStack(alignment: .leading, spacing: 4) {
                    Text("邀請碼").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Text(d.group.inviteCode)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Spacer()
                        Button(m.copiedGroup == id ? "已複製 ✓" : "複製邀請") { m.actions?.copyInvite(d.group) }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))

                HStack {
                    Button("出題") { m.actions?.go(.ask(id)) }
                        .buttonStyle(.borderedProminent)
                    Button(d.group.muted ? "取消靜音" : "靜音") { m.actions?.toggleMute(groupId: id) }
                }

                SectionLabel(text: "題目")
                if d.questions.isEmpty {
                    Hint(text: "還沒有題目，出第一題吧。")
                } else {
                    CappedList(count: d.questions.count, rowHeight: 52, maxHeight: 230) {
                        ForEach(d.questions) { q in
                            Row(title: q.text, subtitle: status(q), accent: !q.closed && !q.answered) {
                                m.actions?.openQuestion(q)
                            }
                        }
                    }
                }
            }
        } else {
            HStack { ProgressView().controlSize(.small); Hint(text: "載入中…") }
        }
    }

    func status(_ q: Question) -> String {
        if q.closed { return q.results != nil ? "已開獎 · \(q.answeredCount) 人回答" : "已截止 · 回答不足 3 人" }
        if !q.answered { return "待你回答 · \(q.authorName) · \(timeLeft(q.closesAt))" }
        return "已回答 · \(q.answeredCount)／\(q.memberCount) · \(timeLeft(q.closesAt))"
    }
}

struct CreateGroupView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("群組名稱，例如：後端組", text: $m.groupName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { m.actions?.createGroup() }
            Hint(text: "建立後會拿到一組邀請碼，傳給朋友就能加入。")
            Button("建立") { m.actions?.createGroup() }
                .buttonStyle(.borderedProminent)
                .disabled(m.groupName.trimmingCharacters(in: .whitespaces).isEmpty || m.busy)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct JoinView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("8 碼邀請碼", text: $m.joinCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { m.actions?.joinGroup() }
            Button("加入") { m.actions?.joinGroup() }
                .buttonStyle(.borderedProminent)
                .disabled(m.joinCode.trimmingCharacters(in: .whitespaces).count < 8 || m.busy)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - 出題

struct AskView: View {
    @ObservedObject var m: Model
    let groupId: Int

    var hasOptions: Bool { m.askKind == "choice" || m.askKind == "multi" }

    var valid: Bool {
        guard m.askText.trimmingCharacters(in: .whitespaces).count >= 2 else { return false }
        guard hasOptions else { return true }
        let opts = m.askOptions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return opts.count >= 2 && Set(opts).count == opts.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 情境範本：點一下帶入設定，內容都可以再改
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(AskTemplate.all) { t in
                    Button(action: { m.actions?.applyTemplate(t) }) {
                        Text(t.label)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(m.askTemplate == t.id ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("題型", selection: $m.askKind) {
                Text("單選").tag("choice")
                Text("多選").tag("multi")
                Text("評分").tag("scale")
                Text("文字").tag("text")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("想問大家什麼？", text: $m.askText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            if hasOptions {
                ForEach(m.askOptions.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        TextField("選項 \(i + 1)", text: option(i))
                            .textFieldStyle(.roundedBorder)
                        if m.askOptions.count > 2 {
                            IconButton(symbol: "minus.circle", help: "刪除選項") {
                                if m.askOptions.indices.contains(i) { m.askOptions.remove(at: i) }
                            }
                        }
                    }
                }
                if m.askOptions.count < 6 {
                    Button("＋ 新增選項") { m.askOptions.append("") }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            } else if m.askKind == "scale" {
                HStack(spacing: 6) {
                    TextField("1 分代表…", text: $m.askLow).textFieldStyle(.roundedBorder)
                    TextField("5 分代表…", text: $m.askHigh).textFieldStyle(.roundedBorder)
                }
            } else {
                Hint(text: "成員用一句話回答（最多 140 字）。")
            }

            Toggle(isOn: $m.askAnonymous) {
                Text(m.askAnonymous ? "匿名（滿 3 人回答才顯示結果）" : "具名（大家會看到誰回答了什麼）").font(.caption)
            }
            Toggle(isOn: $m.askLive) {
                Text(m.askLive ? "回答後立刻看到結果" : "截止或全員答完才開獎").font(.caption)
            }

            Picker("截止", selection: $m.askHours) {
                Text("30 分").tag(0.5)
                Text("1 時").tag(1.0)
                Text("4 時").tag(4.0)
                Text("1 天").tag(24.0)
                Text("3 天").tag(72.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button("發問") { m.actions?.askQuestion(groupId: groupId) }
                .buttonStyle(.borderedProminent)
                .disabled(!valid || m.busy)
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

    var progress: String { "\(q.answeredCount)／\(q.memberCount) 人已答 · \(timeLeft(q.closesAt))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(q.closed ? "🎉 開獎 · \(q.groupName)" : "\(q.groupName) · \(q.authorName) 出題")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(q.text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if q.hasResults {
                results
                Text(q.closed ? "\(q.answeredCount)／\(q.memberCount) 人回答 · \(q.isAnonymous ? "匿名" : "具名")"
                              : "進行中 · \(progress)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if q.closed {
                Text(q.hiddenReason ?? "結果未公開")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if q.answered {
                Text("✓ 已回答 · \(q.hiddenReason ?? "開獎時通知你")")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Text(progress).font(.caption2).foregroundStyle(.tertiary)
            } else {
                answerUI
                Text("\(q.isAnonymous ? "匿名 · ≥3 人回答才公開" : "具名 · 大家會看到你的回答")\(q.isLive ? " · 回答後立刻看結果" : "")")
                    .font(.caption2)
                    .foregroundStyle(q.isAnonymous ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                Text(progress).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 回答

    @ViewBuilder var answerUI: some View {
        switch q.qKind {
        case "multi":
            VStack(spacing: 6) {
                ForEach(q.options.indices, id: \.self) { i in
                    let on = m.multiSelection.contains(i)
                    Button(action: { if on { m.multiSelection.remove(i) } else { m.multiSelection.insert(i) } }) {
                        HStack {
                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                            Text(q.options[i])
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(on ? 0.1 : 0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("送出（已選 \(m.multiSelection.count) 個）") { m.actions?.vote(Array(m.multiSelection).sorted()) }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.multiSelection.isEmpty || m.busy)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case "scale":
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { i in
                        Button(action: { m.actions?.vote(i) }) {
                            Text("\(i + 1)").font(.title3.weight(.semibold)).frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(m.busy)
                    }
                }
                scaleLabels
            }
        case "text":
            VStack(alignment: .leading, spacing: 6) {
                TextField("寫下你的回答（最多 140 字）", text: $m.answerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Button("送出") { m.actions?.vote(m.answerText.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || m.answerText.count > 140 || m.busy)
            }
        default:
            VStack(spacing: 6) {
                ForEach(q.options.indices, id: \.self) { i in
                    Button(action: { m.actions?.vote(i) }) {
                        Text(q.options[i]).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(m.busy)
                }
            }
        }
    }

    @ViewBuilder var scaleLabels: some View {
        if q.scaleLow != nil || q.scaleHigh != nil {
            HStack {
                Text(q.scaleLow.map { "1 = \($0)" } ?? "")
                Spacer()
                Text(q.scaleHigh.map { "5 = \($0)" } ?? "")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: 結果

    @ViewBuilder var results: some View {
        if let texts = q.texts {
            CappedList(count: texts.count, rowHeight: 44, maxHeight: 220) {
                ForEach(texts.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(texts[i].text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if let name = texts[i].name {
                            Text(name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }
        } else if let counts = q.results {
            // 多選題的百分比以「回答人數」為分母；其他題型以總票數為分母
            let total = max(q.qKind == "multi" ? q.answeredCount : counts.reduce(0, +), 1)
            VStack(alignment: .leading, spacing: 6) {
                if q.qKind == "scale" {
                    let sum = counts.enumerated().reduce(0) { $0 + ($1.offset + 1) * $1.element }
                    Text("平均 \(String(format: "%.1f", Double(sum) / Double(max(counts.reduce(0, +), 1)))) 分")
                        .font(.title3.weight(.semibold))
                    scaleLabels
                }
                ForEach(q.options.indices, id: \.self) { i in
                    let n = counts[safe: i] ?? 0
                    let pct = Double(n) / Double(total)
                    let mine = q.isMyChoice(i)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text((q.qKind == "scale" ? "\(i + 1) 分" : q.options[i]) + (mine ? "（你）" : "")).font(.caption)
                            Spacer()
                            Text("\(Int((pct * 100).rounded()))% · \(n) 票").font(.caption.monospacedDigit())
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(mine ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .frame(width: g.size.width * min(pct, 1))
                            }
                        }
                        .frame(height: 5)
                        if let names = q.voters?[safe: i], !names.isEmpty {
                            Text(names.joined(separator: "、"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

struct OnboardingCard: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WhileAI 已連上 \(m.agentName) ✓")
                .font(.headline)
            Text("建立一個群組，把邀請碼傳給朋友。之後大家等 Agent 時，就能互相出題、匿名回答。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("建立群組") { m.actions?.go(.createGroup) }
                    .buttonStyle(.borderedProminent)
                Button("輸入邀請碼") { m.actions?.go(.join) }
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
            HStack {
                TextField("暱稱", text: $m.nickname)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { m.actions?.saveNickname() }
                Button("儲存") { m.actions?.saveNickname() }
                    .disabled(m.nickname.trimmingCharacters(in: .whitespaces).isEmpty || m.nickname == m.me?.user.name)
            }
            if let notice = m.notice {
                Text(notice).font(.caption).foregroundStyle(.green)
            }

            SectionLabel(text: "跳出卡片")
            Button(m.paused ? "▶︎ 恢復跳出卡片" : "⏸ 暫停 1 小時") { m.actions?.togglePause() }

            if m.canConnectAgents {
                SectionLabel(text: "Agent")
                Button("連接 Codex 與 Claude Code") { m.actions?.go(.connect) }
            }

            Divider()
            HStack {
                Text(m.serverLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("結束 WhileAI") { m.actions?.quit() }
            }
        }
    }
}
