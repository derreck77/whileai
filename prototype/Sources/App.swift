// App 主體：選單列圖示、小框框面板、Agent 事件、與後端同步
import AppKit
import Combine
import SwiftUI

// 無邊框面板預設無法成為 key window，按鈕會吃不到第一下點擊、文字框也無法輸入。
// 搭配 .nonactivatingPanel，成為 key 時不會把 Codex／終端機的視窗切到背景。
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    let model = Model()
    let api = API(base: Store.serverURL)
    var panel: CardPanel!
    var statusItem: NSStatusItem!
    var cancellables = Set<AnyCancellable>()
    var clickMonitor: Any?
    var keyMonitor: Any?

    var identity: Identity?
    var state = Store.load("state.json", as: LocalState.self) ?? LocalState()
    var pendingJoinCode: String?
    var localServer: Process?

    var activeSessions: [String: (agent: Agent, last: Date)] = [:]
    // Claude Code 按 Esc 中斷時不會送 Stop；超過這個時間沒有事件的 session 視為已結束
    let staleAfter: TimeInterval = 45 * 60
    var skippedThisWait = Set<Int>()
    var pendingShow: DispatchWorkItem?
    var pendingHide: DispatchWorkItem?
    var lastShown = Date.distantPast
    var pausedUntil = Date.distantPast { didSet { model.paused = Date() < pausedUntil } }

    // 低干擾設定：任務超過 showDelay 秒才顯示；兩張卡片之間至少隔 minGap 秒；每天最多 dailyLimit 道新題目
    let showDelay = Double(ProcessInfo.processInfo.environment["WHILEAI_DELAY"] ?? "") ?? 8
    let minGap = Double(ProcessInfo.processInfo.environment["WHILEAI_GAP"] ?? "") ?? 180
    let dailyLimit = 5

    /// 目前面板是不是 Agent 工作時自動跳出的卡片（不是使用者自己打開的）
    var isAutoCard: Bool { model.screen == .card }

    func applicationWillFinishLaunching(_ note: Notification) {
        // whileai://join/<邀請碼>
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Store.ensureDir()
        model.actions = self
        model.serverLabel = api.base.replacingOccurrences(of: "https://", with: "")
        setupPanel()
        setupStatusItem()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onAgentEvent(_:)), name: eventNote, object: nil,
            suspensionBehavior: .deliverImmediately)

        ensureLocalServer { [weak self] in
            guard let self = self else { return }
            let saved = Store.load("identity.json", as: Identity.self)
            // 換了伺服器（例如從本機測試改成正式網址）→ 舊身分在新伺服器不存在，重新設定暱稱
            self.identity = (saved?.server ?? "http://127.0.0.1:8787") == self.api.base ? saved : nil
            self.api.token = self.identity?.token
            self.api.onUnauthorized = { [weak self] in self?.identityRejected() }
            self.model.canConnectAgents = self.isPackagedBuild && !self.agentsConnected()
            self.consumePendingInvite()

            if self.isPackagedBuild && !self.agentsConnected() {
                self.openPanel(self.inApplicationsFolder ? .connect : .moveApp)
            } else if self.identity == nil {
                self.openPanel(.welcome)
            } else if let code = self.pendingJoinCode {
                self.join(code: code, openPanelFirst: true)
            }
            self.refresh()
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.pruneStaleSessions()
            self?.refresh()
            if let self = self, self.model.paused, Date() >= self.pausedUntil { self.pausedUntil = .distantPast }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        localServer?.terminate()
    }

    // MARK: - 面板

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
        panel.contentView = NSHostingView(rootView: PanelView(m: model))

        // 內容一變（換畫面、載入資料、選項增減）就重新計算大小，維持掛在選單列圖示下方
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layoutPanel() } }
            .store(in: &cancellables)

        // 使用者自己打開的面板：點外面或按 Esc 就收起（像插件一樣）
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panel.isVisible, !self.isAutoCard else { return }
            self.closePanel()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, let self = self, self.panel.isKeyWindow {   // Esc
                self.isAutoCard ? self.skipCard() : self.closePanel()
                return nil
            }
            return e
        }
    }

    func layoutPanel() {
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var anchorX = screen.maxX - size.width / 2 - 16
        var top = screen.maxY - 6
        if let w = statusItem.button?.window, w.frame.width > 0 {
            anchorX = w.frame.midX
            top = w.frame.minY - 6
        }
        let x = min(max(anchorX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        // 已經在畫面上時，高度變化用短動畫，內容增減才不會跳一下
        if panel.isVisible && panel.alphaValue == 1 && abs(frame.width - panel.frame.width) < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// 使用者打開面板：可以打字、點外面會收起
    func openPanel(_ screen: Screen, stack: [Screen] = []) {
        cancelShow()
        pendingHide?.cancel()
        model.error = nil
        model.notice = nil
        model.stack = stack
        model.screen = screen
        prepare(screen)
        let wasVisible = panel.isVisible
        layoutPanel()
        NSApp.activate(ignoringOtherApps: true)
        if wasVisible {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    /// Agent 工作時自動跳出：不搶鍵盤焦點，使用者可以繼續在終端機打字
    func presentAutoCard() {
        model.stack = []
        model.screen = .card
        model.error = nil
        layoutPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func closePanel() {
        guard panel.isVisible else { return }
        pendingHide?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }

    func hideAutoCard(reason: String?) {
        guard panel.isVisible, isAutoCard else { return }
        if let reason = reason { Store.log(reason, question: model.question?.id) }
        closePanel()
    }

    // 進入畫面前準備資料
    func prepare(_ screen: Screen) {
        switch screen {
        case .group(let id): loadGroup(id)
        case .settings: model.nickname = identity?.name ?? ""
        case .home: refresh()
        case .welcome:
            // 預先填入 Mac 的使用者名稱，多數人按一下「開始」就好
            if model.nickname.isEmpty {
                let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
                model.nickname = String((full.isEmpty ? NSUserName() : full).prefix(24))
            }
        case .join: model.joinCode = ""
        case .question: model.confirmWithdraw = false
        default: break
        }
    }

    // MARK: - 選單列圖示

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "WhileAI")
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let quitItem = NSMenuItem(title: "結束 WhileAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quitItem)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if panel.isVisible && !isAutoCard {
            closePanel()
        } else {
            openPanel(identity == nil ? .welcome : .home)
        }
    }

    func updateBadge() {
        let n = model.feed.pending.count
        statusItem.button?.title = n > 0 ? " \(n)" : ""
    }

    // MARK: - 導覽

    func go(_ screen: Screen) {
        let screen = (screen == .welcome && identity != nil) ? Screen.home : screen
        // 從自動卡片點進其他畫面 → 變成使用者自己打開的面板
        if isAutoCard {
            openPanel(screen, stack: identity == nil ? [] : [.home])
            return
        }
        model.error = nil
        model.notice = nil
        if screen == .welcome || screen == .home {
            model.stack = []
        } else {
            model.stack.append(model.screen)
        }
        model.screen = screen
        prepare(screen)
        if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
    }

    func back() {
        guard let prev = model.stack.popLast() else { return }
        model.error = nil
        model.notice = nil
        model.screen = prev
        prepare(prev)
    }

    /// 取代目前畫面（例如建立群組後直接進到群組，返回時回首頁而不是回建立畫面）
    func replace(with screen: Screen) {
        model.error = nil
        model.screen = screen
        prepare(screen)
    }

    func quit() { NSApp.terminate(nil) }

    /// 出題：首頁或群組頁都可以進來。只有一個群組時自動選它，否則預設上次用的群組
    func startAsk(groupId: Int?) {
        let groups = model.groups
        guard !groups.isEmpty else { go(.createGroup); return }
        let preferred = groupId ?? state.lastGroupId
        model.askGroupId = groups.contains { $0.id == preferred } ? preferred : groups[0].id
        model.askShowSettings = false
        applyTemplate(AskTemplate.all[0])
        go(.ask)
    }

    // MARK: - 本機伺服器

    // 伺服器設在本機（127.0.0.1／localhost）卻連不上時，用 App 內附的後端自己啟動一個。
    // 資料庫放在 ~/.whileai/server.db。連正式伺服器時不會走到這裡。
    func ensureLocalServer(then done: @escaping () -> Void) {
        guard let url = URL(string: api.base), ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              let script = Bundle.main.url(forResource: "server", withExtension: "py", subdirectory: "server")
        else { done(); return }
        var probe = URLRequest(url: url.appendingPathComponent("healthz"), timeoutInterval: 1.5)
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
                    self.model.error = "無法啟動本機伺服器：\(error.localizedDescription)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
            }
        }.resume()
    }

    // MARK: - 身分

    func submitNickname() {
        let name = model.nickname.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !model.busy else { return }
        model.busy = true
        model.error = nil
        struct Created: Codable { let token: String; let user: UserInfo }
        api.call("POST", "/api/users", body: ["name": name], as: Created.self) { [weak self] r in
            guard let self = self else { return }
            self.model.busy = false
            switch r {
            case .success(let c):
                self.identity = Identity(token: c.token, name: c.user.name, server: self.api.base)
                Store.save(self.identity, to: "identity.json")
                self.api.token = c.token
                Store.log("nickname_set")
                self.model.me = Me(user: c.user, groups: [])
                self.go(.home)
                if let code = self.pendingJoinCode { self.join(code: code, openPanelFirst: false) }
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    func saveNickname() {
        let name = model.nickname.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        struct Renamed: Codable { let user: UserInfo }
        api.call("PATCH", "/api/me", body: ["name": name], as: Renamed.self) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let u):
                self.identity?.name = u.user.name
                Store.save(self.identity, to: "identity.json")
                self.model.notice = "已儲存 ✓"
                self.refresh()
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    func identityRejected() {
        guard identity != nil else { return }
        identity = nil
        api.token = nil
        model.me = nil
        model.feed = Feed(pending: [], results: [])
        updateBadge()
        openPanel(.welcome)
        model.error = "伺服器上找不到你的身分，請重新取一個暱稱。"
    }

    // MARK: - 同步

    func refresh(then: (() -> Void)? = nil) {
        guard identity != nil else { then?(); return }
        api.call("GET", "/api/feed", as: Feed.self) { [weak self] r in
            guard let self = self else { return }
            if case .success(let f) = r {
                self.model.feed = f
                self.model.unseenResults = f.results.filter { !self.state.seenResults.contains($0.id) }
            }
            self.updateBadge()
            then?()
        }
        api.call("GET", "/api/me", as: Me.self) { [weak self] r in
            if case .success(let me) = r { self?.model.me = me }
        }
    }

    func loadGroup(_ id: Int) {
        scheduleNoticeClear()
        api.call("GET", "/api/groups/\(id)", as: GroupDetail.self) { [weak self] r in
            switch r {
            case .success(let d): self?.model.details[id] = d
            case .failure(.message(let m)): self?.model.error = m
            }
        }
    }

    // 成功訊息顯示幾秒後自己消失
    var noticeTimer: DispatchWorkItem?
    func scheduleNoticeClear() {
        noticeTimer?.cancel()
        guard model.notice != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.model.notice = nil }
        noticeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - 群組

    func createGroup() {
        let name = model.groupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !model.busy else { return }
        model.busy = true
        api.call("POST", "/api/groups", body: ["name": name], as: GroupDetail.self) { [weak self] r in
            guard let self = self else { return }
            self.model.busy = false
            switch r {
            case .success(let d):
                self.model.details[d.group.id] = d
                self.model.groupName = ""
                Store.log("group_created")
                self.refresh()
                self.replace(with: .group(d.group.id))
                self.model.notice = nil
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    func joinGroup() {
        guard let code = extractInviteCode(model.joinCode) else {
            model.error = "找不到邀請碼。請貼上朋友傳來的邀請訊息，或輸入 8 碼邀請碼。"
            return
        }
        join(code: code, openPanelFirst: false)
    }

    /// 「貼上邀請」：按下才讀取剪貼簿，整段邀請訊息或連結都可以
    func pasteInvite() {
        guard let text = NSPasteboard.general.string(forType: .string), let code = extractInviteCode(text) else {
            model.error = "剪貼簿裡沒有邀請碼。請先複製朋友傳來的邀請訊息。"
            return
        }
        model.joinCode = code
        join(code: code, openPanelFirst: false)
    }

    func join(code: String, openPanelFirst: Bool) {
        guard !model.busy else { return }
        pendingJoinCode = nil
        if openPanelFirst { openPanel(.join, stack: [.home]); model.joinCode = code }
        model.busy = true
        model.error = nil
        api.call("POST", "/api/invites/\(code)/join", as: GroupDetail.self) { [weak self] r in
            guard let self = self else { return }
            self.model.busy = false
            switch r {
            case .success(let d):
                self.model.details[d.group.id] = d
                self.model.joinCode = ""
                Store.log("joined_group")
                self.refresh()
                self.model.stack = [.home]
                self.replace(with: .group(d.group.id))
                self.model.notice = "已加入「\(d.group.name)」"
                // 一進來就有事可做：直接打開第一道還沒回答的題目
                if let first = d.questions.last(where: { !$0.closed && !$0.answered }) {
                    self.model.stack = [.home, .group(d.group.id)]
                    self.showQuestion(first, remaining: d.questions.filter { !$0.closed && !$0.answered }.count - 1)
                    self.model.screen = .question
                    self.model.notice = "已加入「\(d.group.name)」，先答一題吧"
                }
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    // setup.sh <邀請碼> 會把邀請碼寫在這個檔案，App 啟動時讀取一次
    func consumePendingInvite() {
        let url = dataDir.appendingPathComponent("pending_join")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        if let code = extractInviteCode(text) { pendingJoinCode = code }
    }

    func toggleMute(groupId: Int) {
        guard let g = model.details[groupId]?.group else { return }
        struct OK: Codable { let ok: Bool }
        api.call("POST", "/api/groups/\(groupId)/mute", body: ["muted": !g.muted], as: OK.self) { [weak self] _ in
            self?.loadGroup(groupId)
            self?.refresh()
        }
    }

    func copyInvite(_ g: Group) {
        var text = "來 WhileAI 一起玩「\(g.name)」！等 Agent 的空檔互相出題。\n\n邀請碼：\(g.inviteCode)\n已經有 WhileAI：點選單列的 ⏳ →「加入」→「貼上邀請」"
        if let install = Store.installURL, let repo = URL(string: install) {
            // 安裝指令直接帶邀請碼，裝完就自動加入
            text += "\n還沒安裝（在終端機貼上這一行）：\ngit clone \(install).git && cd \(repo.lastPathComponent) && ./setup.sh \(g.inviteCode)"
        }
        text += "\n不裝 App 也能用網頁回答：\(g.inviteUrl)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.copiedGroup = g.id
        Store.log("invite_copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.model.copiedGroup == g.id { self?.model.copiedGroup = nil }
        }
    }

    /// 換群組時，依新群組的人數重新套用匿名／具名的預設
    func selectAskGroup(_ id: Int) {
        model.askGroupId = id
        if (model.askGroup?.memberCount ?? 3) < 3 {
            model.askAnonymous = false
            model.askLive = true
        }
    }

    func applyTemplate(_ t: AskTemplate) {
        model.askTemplate = t.id
        model.askKind = t.kind
        model.askText = t.text
        model.askOptions = t.options.isEmpty ? ["", ""] : t.options
        // 群組不到 3 人時，匿名題永遠不會開獎，所以預設改成具名
        let small = (model.askGroup?.memberCount ?? 3) < 3
        model.askAnonymous = small ? false : t.anonymous
        model.askLive = small ? true : t.live
        model.askHours = t.hours
        model.askLow = t.low
        model.askHigh = t.high
        model.error = nil
    }

    func askQuestion() {
        guard !model.busy, let groupId = model.askGroupId else { return }
        var body: [String: Any] = ["text": model.askText, "kind": model.askKind, "anonymous": model.askAnonymous,
                                   "live": model.askLive, "hours": model.askHours]
        if model.askKind == "choice" || model.askKind == "multi" {
            body["options"] = model.askOptions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if model.askKind == "scale" {
            body["config"] = ["low": model.askLow.trimmingCharacters(in: .whitespaces),
                              "high": model.askHigh.trimmingCharacters(in: .whitespaces)]
        }
        model.busy = true
        model.error = nil
        Store.log("ask_submitted", extra: ["kind": model.askKind, "template": model.askTemplate,
                                           "anonymous": model.askAnonymous, "live": model.askLive])
        api.call("POST", "/api/groups/\(groupId)/questions", body: body, as: Question.self) { [weak self] r in
            guard let self = self else { return }
            self.model.busy = false
            switch r {
            case .success(let q):
                Store.log("asked")
                self.state.lastGroupId = groupId
                Store.save(self.state, to: "state.json")
                self.refresh()
                // 發完回到群組頁，看得到剛出的題目
                self.model.stack = [.home]
                self.replace(with: .group(groupId))
                let others = max(q.memberCount - 1, 0)
                self.model.notice = others > 0 ? "已發出。\(others) 位成員會在等 Agent 時看到。"
                                               : "已發出。邀請朋友加入後，他們就會看到。"
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    // MARK: - 題目

    func openQuestion(_ q: Question) {
        showQuestion(q, remaining: model.feed.pending.filter { $0.id != q.id }.count)
        go(.question)
    }

    /// 把題目放進面板（不改變目前是哪個畫面）
    func showQuestion(_ q: Question, remaining: Int) {
        model.multiSelection = []
        model.answerText = ""
        model.confirmWithdraw = false
        model.question = q
        model.remaining = max(remaining, 0)
        markSeenIfClosed(q)
    }

    /// 答完後想繼續：直接換成下一道待答題（自動卡片和手動打開的畫面都適用）
    func showNextPending() {
        let current = model.question?.id
        guard let next = model.feed.pending.first(where: { $0.id != current }) else { return }
        pendingHide?.cancel()
        showQuestion(next, remaining: model.feed.pending.filter { $0.id != next.id && $0.id != current }.count)
        Store.log("next_question", question: next.id, extra: ["auto": isAutoCard])
    }

    func closeEarly() {
        guard let q = model.question, q.isMine, !model.busy else { return }
        model.busy = true
        api.call("POST", "/api/questions/\(q.id)/close", as: Question.self) { [weak self] r in
            guard let self = self else { return }
            self.model.busy = false
            switch r {
            case .success(let updated):
                self.model.question = updated
                self.markSeenIfClosed(updated)
                self.loadGroup(q.groupId)
                self.refresh()
                Store.log("closed_early", question: q.id)
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    func withdraw() {
        guard let q = model.question, q.isMine, !model.busy else { return }
        // 第一下只是確認，第二下才真的撤回
        guard model.confirmWithdraw else { model.confirmWithdraw = true; return }
        model.busy = true
        struct OK: Codable { let ok: Bool }
        api.call("DELETE", "/api/questions/\(q.id)", as: OK.self) { [weak self] r in
            guard let self = self else { return }
            self.model.busy = false
            switch r {
            case .success:
                Store.log("withdrawn", question: q.id)
                self.refresh()
                self.back()
                self.model.notice = "已撤回題目"
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    func markSeenIfClosed(_ q: Question) {
        guard q.closed, !state.seenResults.contains(q.id) else { return }
        state.seenResults.append(q.id)
        Store.save(state, to: "state.json")
        model.unseenResults.removeAll { $0.id == q.id }
    }

    func vote(_ answer: Any) {
        guard let q = model.question, !model.busy else { return }
        model.busy = true
        model.error = nil
        api.call("POST", "/api/questions/\(q.id)/vote", body: ["answer": answer], as: Question.self) { [weak self] r in
            guard let self = self else { return }
            self.model.busy = false
            switch r {
            case .success(let updated):
                self.model.question = updated
                self.markSeenIfClosed(updated)   // 我是最後一個回答的人 → 直接看到開獎
                self.model.feed = Feed(pending: self.model.feed.pending.filter { $0.id != q.id },
                                       results: self.model.feed.results)
                self.model.remaining = self.model.feed.pending.count
                self.updateBadge()
                self.loadGroup(q.groupId)
                // 只記錄題型與是否來自自動卡片，不記錄回答內容
                Store.log("voted", question: q.id, extra: ["kind": q.qKind, "auto": self.isAutoCard])
                if self.isAutoCard {
                    if self.model.phase == .done {
                        self.scheduleHide(after: 5)
                    } else if !updated.hasResults && self.model.remaining == 0 {
                        self.scheduleHide(after: 2)   // 沒有結果可看、也沒有下一題：不佔著畫面
                    }
                }
            case .failure(.message(let m)):
                self.model.error = m
            }
        }
    }

    // MARK: - Agent 事件（Codex、Claude Code）

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
            // 工作優先：Agent 需要你的時候立刻收起自動卡片（使用者自己打開的面板不動）
            activeSessions[session]?.last = Date()
            cancelShow()
            hideAutoCard(reason: "agent_needs_you")
        case "Stop", "Interrupt", "SessionEnd", "StopFailure":
            activeSessions[session] = nil
            updateAgentName(fallback: agent)
            if activeSessions.isEmpty {
                cancelShow()
                if panel.isVisible && isAutoCard { agentFinished() }
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
            if isAutoCard && model.phase == .working { hideAutoCard(reason: nil) }
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
            guard !self.activeSessions.isEmpty, !self.panel.isVisible else { return }
            if let q = self.nextQuestion() { self.showAutoQuestion(q) } else if self.needsOnboarding { self.showOnboarding() }
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
        let reading = model.question?.closed == true || model.question?.answered == true
        scheduleHide(after: reading ? 5 : 2.5)
    }

    func scheduleHide(after seconds: Double) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideAutoCard(reason: nil) }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func skipCard() {
        if let q = model.question, !model.onboarding, !q.closed { skippedThisWait.insert(q.id) }
        hideAutoCard(reason: "skipped")
    }

    // 選題：先開獎、再待答題
    var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func nextQuestion() -> Question? {
        if let r = model.feed.results.first(where: { !state.seenResults.contains($0.id) }) { return r }
        let shownToday = state.shownByDay[today] ?? []
        return model.feed.pending.first { q in
            !skippedThisWait.contains(q.id) && (shownToday.contains(q.id) || shownToday.count < dailyLimit)
        }
    }

    // 已設定暱稱、還沒加入任何群組、也還沒看過引導 → 第一次等待時顯示一次
    var needsOnboarding: Bool {
        identity != nil && model.me != nil && model.me?.groups.isEmpty == true && !state.onboardingShown
    }

    func showOnboarding() {
        pendingHide?.cancel()
        model.question = nil
        model.onboarding = true
        model.phase = .working
        lastShown = Date()
        state.onboardingShown = true
        Store.save(state, to: "state.json")
        presentAutoCard()
        Store.log("onboarding_shown")
    }

    func showAutoQuestion(_ q: Question) {
        pendingHide?.cancel()
        model.onboarding = false
        showQuestion(q, remaining: model.feed.pending.filter { $0.id != q.id }.count)
        model.phase = .working
        lastShown = Date()
        if !q.closed {
            var shown = state.shownByDay[today] ?? []
            if !shown.contains(q.id) { shown.append(q.id) }
            state.shownByDay = [today: shown]   // 只保留今天
            Store.save(state, to: "state.json")
        }
        presentAutoCard()
        Store.log(q.closed ? "result_shown" : "shown", question: q.id, extra: ["agent": model.agentName])
    }

    func togglePause() {
        if Date() < pausedUntil {
            pausedUntil = .distantPast
            Store.log("resumed")
        } else {
            pausedUntil = Date().addingTimeInterval(3600)
            cancelShow()
            hideAutoCard(reason: nil)
            Store.log("paused")
        }
    }

    // MARK: - 邀請連結 whileai://join/<邀請碼>

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s), url.host == "join" else { return }
        let code = url.lastPathComponent.uppercased()
        if identity == nil {
            pendingJoinCode = code
            openPanel(.welcome)
        } else {
            join(code: code, openPanelFirst: true)
        }
    }

    // MARK: - 連接 Codex 與 Claude Code（打包版：App 自己設定 hooks）

    var executablePath: String { Bundle.main.executablePath ?? "" }
    var isPackagedBuild: Bool { Bundle.main.url(forResource: "hooks_config", withExtension: "py") != nil }
    var inApplicationsFolder: Bool {
        !executablePath.contains("/AppTranslocation/") && executablePath.contains("/Applications/")
    }

    func agentsConnected() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".codex/hooks.json", ".claude/settings.json"].contains { rel in
            (try? String(contentsOf: home.appendingPathComponent(rel), encoding: .utf8))?.contains(executablePath) == true
        }
    }

    func connectAgents() {
        guard let config = Bundle.main.url(forResource: "hooks_config", withExtension: "py"),
              let trust = Bundle.main.url(forResource: "trust_hooks", withExtension: "py") else { return }
        guard inApplicationsFolder else { go(.moveApp); return }
        model.connecting = true
        model.error = nil
        let exe = executablePath
        DispatchQueue.global(qos: .userInitiated).async {
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
            let (code, out) = run([config.path, "install", exe])
            let (tcode, _) = code == 0 ? run([trust.path]) : (1, "")
            DispatchQueue.main.async {
                self.model.connecting = false
                guard code == 0 else { self.model.error = "連接失敗：\(out)"; return }
                self.installLoginItem()
                self.model.canConnectAgents = false
                Store.log("agents_connected")
                self.model.notice = tcode == 0 ? "已連接 Codex 與 Claude Code ✓"
                                               : "已連接 Claude Code ✓（Codex 需要在 CLI 輸入 /hooks 信任）"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.identity == nil ? self.go(.welcome) : self.go(.home)
                }
            }
        }
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
}
