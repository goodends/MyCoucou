import Foundation
import SwiftUI
import Combine


@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden
    @Published var view: IslandView = .overview

    /// The island's own NSWindow, set once by IslandWindowController at boot.
    /// Used by the overscroll-back gesture to filter NSEvent.scrollWheel to
    /// scrolls that targeted this window — `NSEvent.addLocalMonitorForEvents`
    /// delivers every scroll in the foreground app's process otherwise.
    @Published var islandWindow: NSWindow? = nil

    /// `true` when every nested ScrollView inside the island is at the
    /// bottom (so the user has run out of room to scroll down any further).
    /// `true` by default because views without any ScrollView (e.g. the
    /// home view) should still accept the gesture immediately. The
    /// bottom-of-chat predicate here is what the gesture actually checks.
    @Published var scrollAtBottom: Bool = true

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

    // Active Claude Code sessions (one per running Claude process). Mirrors the hook's
    // session_id, used by the overview's right-side list. Ordered most-recent-first;
    // HookServer maintains order. Not persisted — SessionStart re-fires on process launch.
    @Published var claudeSessions: [ClaudeSession] = []

    /// Session ids the user has explicitly told the app to stop monitoring.
    /// Persisted so a restart doesn't bring the noise back. `upsertClaudeSession`
    /// checks this and skips the entry, which keeps the right-side list clean
    /// even as the underlying process keeps firing hook events.
    @Published var hiddenClaudeSessionIds: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "hiddenClaudeSessionIds") ?? []
    ) {
        didSet { UserDefaults.standard.set(Array(hiddenClaudeSessionIds), forKey: "hiddenClaudeSessionIds") }
    }

    /// The session behind each hidden id, kept so "Resume" can put it straight
    /// back. Only the ids are persisted — after a restart a resumed session
    /// relies on the process scan (or its next hook event) to return.
    var hiddenClaudeSessions: [String: ClaudeSession] = [:]

    /// Per-session step log (rolling window of ~20). Populated by HookServer so the
    /// overview's left ticker can show real-time activity even when the focus task
    /// is shared across concurrent Claude sessions.
    @Published var claudeSessionSteps: [String: [String]] = [:]

    /// When set, ChatSessionView reads the JSONL for this Claude session instead of
    /// `focusTask`. Set when the user taps a Claude-session pill on the overview.
    /// Cleared when that session ends.
    @Published var focusedSessionId: String? = nil

    /// Convenience: the ClaudeSession matching `focusedSessionId`, or nil.
    var focusedClaudeSession: ClaudeSession? {
        guard let id = focusedSessionId else { return nil }
        return claudeSessions.first { $0.sessionId == id }
    }

    /// cwd to look up when jumping to a terminal: prefer the focused Claude
    /// session's (it always carries one), fall back to the focus task's.
    private var terminalLookupCwd: String? {
        if let cwd = focusedClaudeSession?.cwd, !cwd.isEmpty { return cwd }
        if let cwd = focusTask?.sessionCwd, !cwd.isEmpty { return cwd }
        return nil
    }

    /// Jump to the Orca terminal hosting `sessionId`, or the focused session
    /// when `sessionId` is nil. Prefers Orca — it focuses the exact
    /// terminal tab rather than just raising the app. Returns false when
    /// Orca isn't installed/running or doesn't host this session, so the
    /// caller falls back to its usual app activation.
    @discardableResult
    func jumpToOrcaTerminal(sessionId: String? = nil) async -> Bool {
        // Non-Orca sessions (Warp, Terminal.app, iTerm2, Ghostty, …) live
        // in a regular terminal — there's no Orca tab to switch to, and
        // raising Orca here would put the wrong app in front of the user.
        // Return false up front so the caller falls through to
        // ClaudeHost.activate(hostApp) and raises the actual terminal.
        if let lookupSid = sessionId ?? focusedSessionId, !lookupSid.isEmpty,
           let session = claudeSessions.first(where: { $0.sessionId == lookupSid }),
           let host = session.hostApp, !host.isEmpty,
           host != "com.stablyai.orca" {
            return false
        }
        guard OrcaCLIBridge.isInstalled else { return false }
        // Bind the requested session to a handle. The fast path is the
        // ORCA_TERMINAL_HANDLE binding written by HookServer on every
        // hook event — exact even when the cwd hosts multiple Claude
        // sessions. Fall back to a cwd + lastOutputAt heuristic only when
        // the binding hasn't been established yet (no event has fired for
        // the session, e.g. the user jumped before any hook arrived) and
        // cache the result for the next jump.
        let sid = sessionId ?? focusedSessionId
        var handle: String?
        if let sid, !sid.isEmpty {
            handle = await resolveOrcaHandle(for: sid)
        } else {
            // No session to key on — fall back to whatever the chat is about.
            handle = await OrcaCLIBridge.shared.handle(forCwd: terminalLookupCwd ?? "")
        }
        guard let handle, !handle.isEmpty else { return false }
        // Raise the Orca window first — `orca terminal switch` only changes
        // the selected tab inside the app, it doesn't bring the window
        // forward on macOS. Then give the activation a moment to settle:
        // Orca restores its own remembered tab when the window becomes
        // active, and that restore would clobber our switch if we raced it.
        activateOrcaApp()
        try? await Task.sleep(nanoseconds: 350_000_000)
        do {
            try await OrcaCLIBridge.shared.focus(handle: handle)
            return true
        } catch {
            return false
        }
    }

    private func activateOrcaApp() {
        let bundleId = "com.stablyai.orca"
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId }) {
            running.activate(options: [.activateIgnoringOtherApps])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    /// Orca terminal handle bound per Claude session, keyed by sessionId.
    /// `task.id` is `"integration_claude"` for every Claude pill, so it can't
    /// tell two running sessions apart; the session uuid can. Populated
    /// lazily on the first send, then reused.
    @Published var orcaHandleBySession: [String: String] = [:]

    /// Type `text` into the Orca terminal hosting the focused Claude session
    /// and submit it. Returns false when Orca can't reach the session (not
    /// installed, no matching terminal, or the agent didn't take the prompt)
    /// so the caller can show its "not sent" hint.
    @discardableResult
    func sendToOrcaTerminal(_ text: String) async -> Bool {
        // Non-Orca sessions (Warp, Terminal.app, iTerm2, Ghostty, …) have
        // no Orca handle — `handle(forCwd:)` would match on cwd alone and
        // land on the wrong tab when an Orca session happens to share the
        // worktree, sending the message to an unrelated agent. Bail out so
        // the caller can show its "not sent" hint instead of misrouting.
        if let key = focusedSessionId ?? focusTask?.id, !key.isEmpty,
           let session = claudeSessions.first(where: { $0.sessionId == key }),
           let host = session.hostApp, !host.isEmpty,
           host != "com.stablyai.orca" {
            return false
        }
        guard OrcaCLIBridge.isInstalled else { return false }
        guard let key = focusedSessionId ?? focusTask?.id, !key.isEmpty else { return false }

        var handle = orcaHandleBySession[key]
        if handle == nil { handle = await resolveOrcaHandle(for: key) }
        guard let handle else { return false }
        do {
            return try await OrcaCLIBridge.shared.send(handle: handle, text: text)
        } catch {
            return false
        }
    }

    /// Find the Orca terminal for `sessionId`, most precise source first, and
    /// cache the result. Shared by the jump and the send path so both agree on
    /// which tab a session lives in — they used to resolve differently, and a
    /// send that landed on a different tab than the jump would be very hard to
    /// notice.
    ///
    /// 1. A handle already bound to this session (from ORCA_TERMINAL_HANDLE,
    ///    which the relay forwards on every event) is exact.
    /// 2. A scanned session has no bound handle, but we know its Orca pane.
    /// 3. cwd is the last resort and only names a *folder* — two sessions in
    ///    one folder both resolve to the most recently active terminal there,
    ///    which is why 2 has to come first.
    private func resolveOrcaHandle(for sessionId: String) async -> String? {
        if let bound = orcaHandleBySession[sessionId] { return bound }
        let session = claudeSessions.first { $0.sessionId == sessionId }
        if let session, let pane = session.pid.flatMap({ orcaPaneByPid[$0] }),
           let byPane = await OrcaCLIBridge.shared.handle(paneKey: pane) {
            orcaHandleBySession[sessionId] = byPane
            return byPane
        }
        guard let cwd = session?.cwd ?? terminalLookupCwd, !cwd.isEmpty else { return nil }
        guard let byCwd = await OrcaCLIBridge.shared.handle(forCwd: cwd) else { return nil }
        orcaHandleBySession[sessionId] = byCwd
        return byCwd
    }

    /// The Claude session that should drive the OverviewView's left card:
    /// either the user-tapped one, or the most-recently-active session when none
    /// was explicitly chosen. Keeps the home view in sync with what the user is
    /// actually working on, regardless of which task the focus pill points at.
    var overviewSession: ClaudeSession? {
        if let s = focusedClaudeSession { return s }
        return claudeSessions.first
    }

    /// Whether the overview has something real to show.
    ///
    /// `integration_claude` is a permanent catalog placeholder — it means
    /// "Claude Code is wired up", not "a session is running". Rendering it as
    /// the left card's character painted an empty Mochi under a host name
    /// Coucou knew nothing about, so the home view claimed an agent that
    /// didn't exist. It only counts once a hook event has given it steps to
    /// report; any other pill (Codex, Copilot…) counts on its own.
    var hasOverviewContent: Bool {
        if overviewSession != nil { return true }
        guard let task = focusTask else { return false }
        return task.id != "integration_claude" || !task.steps.isEmpty
    }

    /// Synthesise an `AgentTask` for a Claude session so we can feed existing
    /// ticker / pill views that take an AgentTask. Source is always `.claudeCode`;
    /// `id` carries the sessionId so list lookups still work.
    func overviewTask(for session: ClaudeSession) -> AgentTask {
        let botState: BotState
        switch session.state {
        case .spawning: botState = .thinking
        case .working:  botState = .working
        case .finished: botState = .finished
        case .stopped:  botState = .idle
        }
        let steps = claudeSessionSteps[session.sessionId] ?? []
        return AgentTask(
            id: "claude:\(session.sessionId)",
            name: session.displayName,
            color: session.bodyColor,
            state: botState,
            stepIndex: max(0, steps.count - 1),
            steps: steps,
            source: .claudeCode,
            sessionCwd: session.cwd,
            sessionId: session.sessionId,
            sessionBundleId: session.sessionBundleId,
            hostApp: session.hostApp,
            outfit: session.outfit
        )
    }

    // Bot state override
    @Published var stateOverride: BotState? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Last app active before NotchBuddy (for window context capture)
    var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    @Published var isDraggingBot: Bool = false

    // Desktop Mochi: true while Mochi lives on the desktop instead of the notch
    @Published var mochiOnDesktop: Bool = false

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    /// Views that must not fold away on the auto-close timer: the question card
    /// is blocked waiting for an answer, the notification cards are waiting to
    /// be acknowledged. A pointer moving off the island is neither of those.
    var holdsIslandOpen: Bool {
        guard mode == .expanded else { return false }
        switch view {
        case .question: return true
        // A queued question or permission holds a hook open on a clock, so the
        // stack stays up while one is waiting even if every finished session
        // below it has already been acknowledged.
        case .finished: return !notifications.isEmpty || inboxHasBlockingItem
        default: return false
        }
    }

    /// Rows in the inbox that hold a hook fd open and run on a deadline.
    var inboxHasBlockingItem: Bool {
        !pendingApprovals.isEmpty || !pendingQuestions.isEmpty
    }

    /// The finished stack is on screen with something waiting on it.
    var isShowingNotification: Bool {
        mode == .expanded && view == .finished && !inbox.isEmpty
    }

    // Keyboard navigation — index of the selected item within the current card's list (nil = none)
    @Published var cardSelection: Int? = nil
    // Number of navigable items in the card currently on screen (0 = no list)
    @Published var cardItemCount: Int = 0

    // Sound enabled — persisted
    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Mochi outfit selection — persisted
    @Published var mochiOutfitSelection: Outfit = .auto {
        didSet { Outfit.stored = mochiOutfitSelection }
    }
    // A colour of the user's own for each pill's Mochi (pill id → "#RRGGBB") — persisted.
    // Empty means the catalog's colours. PillDefinition.color reads the stored value, so
    // what is built from the catalog follows on its own; the tasks already on the island
    // hold a copy of their colour and are repainted here.
    @Published var pillColors: [String: String] = [:] {
        didSet {
            PillColors.stored = pillColors
            var repainted = tasks
            var changed = false
            for i in repainted.indices {
                guard let def = PillCatalog.definition(for: repainted[i].id),
                      repainted[i].color != def.color else { continue }
                repainted[i].color = def.color
                changed = true
            }
            if changed { tasks = repainted }
        }
    }
    /// Picks a colour for a pill's Mochi; nil, or the pill's own catalog colour, goes back to the default.
    func setPillColor(_ id: String, _ hex: String?) {
        guard let def = PillCatalog.definition(for: id) else { return }
        pillColors = PillColors.picking(hex, for: id, catalogColor: def.defaultColor, in: pillColors)
    }
    // Transient: outfit preview while hovering in wardrobe (overrides resolvedOutfit in BotCanvasView)
    var wardrobePreviewOutfit: Outfit? = nil
    // Per-day seasonal cache — avoids recomputing Easter and date math on every frame
    private var _seasonalCache: (dayOfYear: Int, year: Int, outfit: Outfit)?
    var resolvedOutfit: Outfit {
        if let preview = wardrobePreviewOutfit { return preview }
        guard mochiOutfitSelection == .auto else { return mochiOutfitSelection }
        let cal = Calendar.current
        let now = Date()
        let day  = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        let year = cal.component(.year, from: now)
        if let c = _seasonalCache, c.dayOfYear == day && c.year == year { return c.outfit }
        let outfit = Outfit.seasonal(for: now, calendar: cal)
        _seasonalCache = (dayOfYear: day, year: year, outfit: outfit)
        return outfit
    }

    // The always-on workspace pill (default: VS Code). Persisted.
    @Published var mainPillId: String = PillCatalog.defaultMainPillId {
        didSet { UserDefaults.standard.set(mainPillId, forKey: "mainPill") }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Selected app language ("" = System, else BCP-47 code e.g. "fr")
    @Published var appLanguage: String = {
        let bundleId = Bundle.main.bundleIdentifier ?? "fr.louisraille.NotchBuddy"
        let langs = UserDefaults.standard.persistentDomain(forName: bundleId)?["AppleLanguages"] as? [String]
        return langs?.first ?? ""
    }()

    // Context for prompt (window attach / file)
    
    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    // Hovering the island opens it (folds shortly after the pointer leaves) — persisted, off by default
    @Published var openOnHover: Bool = false {
        didSet { UserDefaults.standard.set(openOnHover, forKey: "openOnHover") }
    }
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — how long the island stays in petit before hiding, persisted (seconds)
    @Published var absenceInterval: TimeInterval = 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Greeting threshold — how long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    // Screen hosting the island (notch screen by default) — persisted
    @Published var islandDisplay: IslandDisplayChoice = .notch {
        didSet { UserDefaults.standard.set(islandDisplay.storageValue, forKey: "islandDisplay") }
    }

    // Pending API result
    @Published var searchResult: SearchResult? = nil

    // Chat conversation history
    @Published var chatHistory: [ChatMessage] = []

    // Requests holding a hook fd open, oldest first. Queued rather than
    // single-slot: a second request used to write "ask" to the first one's fd
    // and take the card, dropping the displaced session into its terminal with
    // nothing on screen saying so. Each entry carries its own deadline.
    @Published var pendingApprovals: [PendingApproval] = [] {
        didSet { updateInboxHeight() }
    }
    @Published var pendingQuestions: [PendingQuestion] = [] {
        didSet {
            QuestionLayout.height = pendingQuestions.first?.question.estimatedIslandHeight
            updateInboxHeight()
        }
    }

    /// The request the island is showing. Derived from the head of each queue
    /// so every existing reader — the FSM's hold, Desktop Mochi's alert face,
    /// the views — keeps working against one item.
    var pendingApproval: ApprovalInfo? { pendingApprovals.first?.info }
    var pendingQuestion: AskQuestion? { pendingQuestions.first?.question }

    // Flat list of FileDiffs per scope, in order of reception.
    //
    // The key is the Claude session id for Claude Code — one Mochi per session
    // means one session's diffs belong to that session alone. Agents with no
    // session concept (Codex, Cursor…) keep the pill id as key.
    //
    // @Published on purpose: the changes view reads only this, never the steps
    // array, so there is no neighbouring write to piggyback on. Mutate by
    // replacing the whole dictionary — `sessionDiffs[key]!.append(…)` does not
    // even trigger willSet.
    @Published var sessionDiffs: [String: [FileDiff]] = [:]
    // Monotonically increasing — never reset, not even in clearSessionDiffs.
    private var nextDiffId: Int = 0

    // Per-scope cap, and a global one: N concurrent sessions × 50 diffs each is
    // real memory (every diff holds up to maxLines lines), and the idle timer
    // only helps for sessions that have actually gone quiet.
    private static let maxDiffsPerScope = 50
    private static let maxDiffsTotal = 200

    @discardableResult
    func appendSessionDiff(_ diff: FileDiff, for scopeKey: String) -> Int {
        guard !scopeKey.isEmpty else { return -1 }
        var d = diff
        d.id = nextDiffId
        nextDiffId += 1
        var dict = sessionDiffs
        var list = dict[scopeKey] ?? []
        list.append(d)
        while list.count > Self.maxDiffsPerScope { list.removeFirst() }
        dict[scopeKey] = list
        // Global trim: evict the scope whose newest diff is oldest. Never drop
        // the last scope — that is the session the user is looking at.
        while dict.count > 1,
              dict.values.reduce(0, { $0 + $1.count }) > Self.maxDiffsTotal,
              let oldestKey = dict.min(by: { ($0.value.last?.id ?? 0) < ($1.value.last?.id ?? 0) })?.key {
            dict[oldestKey] = nil
        }
        sessionDiffs = dict
        return d.id
    }

    /// Diffs for one scope, oldest first.
    func diffs(for scopeKey: String) -> [FileDiff] { sessionDiffs[scopeKey] ?? [] }

    /// One diff by id, searched in `scopeKey` first and then everywhere else.
    /// The fallback matters: ids are globally unique, so a stale id from a
    /// scope that has since been trimmed still resolves instead of showing an
    /// empty card.
    func diff(id: Int, in scopeKey: String?) -> FileDiff? {
        if let scopeKey, let hit = sessionDiffs[scopeKey]?.first(where: { $0.id == id }) {
            return hit
        }
        return sessionDiffs.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Per-file rollup for the changes list.
    func fileChanges(for scopeKey: String) -> [FileChange] {
        DiffLedger.fileChanges(from: diffs(for: scopeKey))
    }

    /// Added / removed lines for one scope, summed over its files. Derived from
    /// `fileChanges`, so a badge showing these can never disagree with the rows
    /// the changes list draws from the same rollup.
    func changeTotals(for scopeKey: String) -> (added: Int, removed: Int) {
        fileChanges(for: scopeKey).reduce(into: (added: 0, removed: 0)) {
            $0.added += $1.added
            $0.removed += $1.removed
        }
    }

    /// Forget everything recorded for one scope. Called when the session ends
    /// or dies, and from the changes view's reset action.
    ///
    /// There is deliberately no idle timeout. An hour of silence silently
    /// rewriting the user's numbers is worse than numbers that keep counting:
    /// a session that keeps working should keep its running total, and the user
    /// can reset it whenever they want a fresh count.
    func clearSessionDiffs(for scopeKey: String) {
        sessionDiffs.removeValue(forKey: scopeKey)
        // nextDiffId intentionally NOT reset — ids remain unique across sessions
    }

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { soundVolume  = v }
        mochiOutfitSelection = Outfit.stored
        pillColors = PillColors.stored
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "openOnHover") as? Bool { openOnHover = v }
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
        if let v = ud.string(forKey: "islandDisplay") { islandDisplay = IslandDisplayChoice(storageValue: v) }
        if let v = ud.string(forKey: "mainPill"), !v.isEmpty,
           PillCatalog.available.contains(where: { $0.id == v && $0.category == .workspace && !$0.comingSoon }) {
            mainPillId = v
        }

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load integration pills
        loadIntegrationTasks()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    /// State the main Mochi (left side of home / chat) should display.
    /// Mirrors the focused Claude session's state — same dot the user sees
    /// on the right-side small avatar — instead of the global integration
    /// task, which goes "busy" whenever any session is working even if the
    /// user is currently looking at an idle one.
    ///
    /// On the finished card the avatar and state must follow the session
    /// that *just completed* (not the focused one), so the main Mochi
    /// reads as the same character that just finished its work.
    var mainMochiState: BotState {
        if let override = stateOverride { return override }
        let session = (view == .finished) ? finishingSession : overviewSession
        if let session {
            switch session.state {
            case .spawning: return .thinking
            case .working:  return .working
            case .finished: return .finished
            case .stopped:  return .idle
            }
        }
        return focusTask?.state ?? .idle
    }

    /// Sessions that hit their Stop event and are waiting to be acknowledged,
    /// newest first. A queue rather than a single slot: two sessions finishing
    /// back to back must both stay visible with their own avatar, final line
    /// and "Open terminal" target.
    @Published var notifications: [AgentNotification] = [] {
        didSet { updateInboxHeight() }
    }

    /// Agent id of the session at the head of the queue — the one that
    /// completed most recently.
    var lastFinishedAgentId: String? { notifications.first?.agentId }
    /// Session uuid of that same event. The agent id (e.g.
    /// "integration_claude") is shared by every Claude session in a project,
    /// so it can't tell two of them apart; the uuid can.
    var lastFinishedSessionId: String? { notifications.first?.sessionId }

    /// The ClaudeSession at the head of the queue, looked up by its uuid. nil
    /// if the session has already been removed or the event didn't carry
    /// a session id. Drives the finished card's avatar and "Open terminal".
    var finishingSession: ClaudeSession? {
        guard let id = lastFinishedSessionId, !id.isEmpty else { return nil }
        return claudeSessions.first { $0.sessionId == id }
    }

    // MARK: - Inbox

    /// Everything waiting on the user — questions and permissions first (they
    /// hold a hook open and run on a clock), finished sessions after.
    var inbox: [InboxItem] {
        InboxItem.ordered(approvals: pendingApprovals,
                          questions: pendingQuestions,
                          notifications: notifications)
    }

    /// The finished view's height follows the whole inbox, not just the
    /// finished sessions — a question row is as tall as a finished card, and
    /// sizing off one of the three arrays left the stack clipped when the
    /// other two grew.
    private func updateInboxHeight() {
        NotificationLayout.height = NotificationLayout.height(forCount: inbox.count)
    }

    /// Hands one inbox row back to whoever raised it. Once the inbox is empty
    /// the finished view has nothing left to show and the island goes home.
    func dismissInboxItem(_ item: InboxItem) {
        switch item {
        case .finished(let n):
            dismissNotification(id: n.id)
        case .question(let q):
            HookServer.shared.releaseQuestion(id: q.id)
        case .approval(let a):
            HookServer.shared.releaseApproval(id: a.id)
        }
        if inbox.isEmpty && view == .finished {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                view = .overview
            }
        }
    }

    /// A session finished: queue its notification. Re-finishing an already
    /// waiting session refreshes its row in place instead of duplicating it.
    func pushNotification(agentId: String, sessionId: String?, kind: AgentNotification.Kind, finalLine: String) {
        let n = AgentNotification(agentId: agentId, sessionId: sessionId, kind: kind, finalLine: finalLine)
        notifications = notifications.pushing(n)
    }

    /// Drop one finished notification. Navigation is `dismissInboxItem`'s job —
    /// this used to go home when the *finished* list emptied, which walked away
    /// from a question still waiting on its hook.
    func dismissNotification(id: String) {
        guard notifications.contains(where: { $0.id == id }) else { return }
        notifications = notifications.removing(id: id)
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        // mainPillId: always reset, never remove (the active workspace tool)
        let isProtected = id == mainPillId
        if isProtected {
            if let idx = tasks.firstIndex(where: { $0.id == id }) {
                let catalogName = PillCatalog.definition(for: id)?.name
                tasks[idx].state      = .idle
                tasks[idx].steps      = []
                tasks[idx].stepIndex  = 0
                tasks[idx].pillBadge  = nil
                if let n = catalogName { tasks[idx].name = n }
            }
            return
        }
        // Not main pill: remove
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = mainPillId }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    // MARK: - Claude session list (right-side overview)

    /// Insert or refresh a Claude Code session. Empty / "unknown" session ids are no-ops.
    /// Existing sessions are updated in place and promoted to the front; new sessions
    /// are prepended so the list stays sorted by recency. Sessions the user has
    /// asked us to stop monitoring (see `hideClaudeSession`) are skipped entirely
    /// so the right-side list stays clean.
    func upsertClaudeSession(
        sessionId: String,
        cwd: String,
        hostApp: String?,
        sessionBundleId: String?,
        projectName: String,
        phase: SessionPhase,
        eventTime: Date,
        pid: Int32? = nil
    ) {
        guard !hiddenClaudeSessionIds.contains(sessionId) else { return }

        // Adopt a session the process scan found. The relay reports the pid of
        // the process that spawned it, so matching on pid is exact — this is
        // the same session we only knew the cwd of, now with its real id and
        // state, rather than a second card for the same process.
        if let pid,
           let idx = claudeSessions.firstIndex(where: { $0.provisional && $0.pid == pid }),
           !claudeSessions.contains(where: { $0.sessionId == sessionId }) {
            var s = claudeSessions[idx]
            s = ClaudeSession(
                id: sessionId, sessionId: sessionId,
                cwd: cwd, hostApp: hostApp, sessionBundleId: sessionBundleId,
                projectName: projectName, state: phase,
                startedAt: s.startedAt, lastEventAt: eventTime,
                pid: pid, bodyColor: s.bodyColor, outfit: s.outfit,
                sessionName: s.sessionName, customName: s.customName,
                scanned: s.scanned
            )
            claudeSessions.remove(at: idx)
            claudeSessions.insert(s, at: 0)
            // The chat can be focused on the placeholder id (tapping a scanned
            // card opens it). Carry that focus over to the real id, or the open
            // chat silently loses its session and never fills in.
            if focusedSessionId == s.sessionId { focusedSessionId = sessionId }
            appendAppLog("nb.log", "adopt scanned session pid=\(pid) → \(sessionId) cwd=\(cwd) name=\(projectName)")
            return
        }

        claudeSessions.upsert(
            sessionId: sessionId, cwd: cwd, hostApp: hostApp,
            sessionBundleId: sessionBundleId, projectName: projectName,
            phase: phase, eventTime: eventTime, pid: pid
        )
    }

    /// Orca-managed worktrees, loaded when the project picker opens. nil until
    /// then — this is a user-initiated list, not something to fetch at launch.
    @Published var orcaWorktrees: [OrcaWorktree]? = nil
    /// Worktrees still loading, or whose load failed. Drives the picker's
    /// "loading" / "couldn't reach Orca" copy.
    @Published var orcaWorktreesLoading = false

    /// Load (once per open) the list of projects a Claude session can be
    /// started in. Returns false when Orca isn't installed or the CLI failed,
    /// so the caller can keep the picker closed.
    @discardableResult
    func loadOrcaWorktrees() async -> Bool {
        guard OrcaCLIBridge.isInstalled else { return false }
        if orcaWorktrees != nil { return true }
        orcaWorktreesLoading = true
        defer { orcaWorktreesLoading = false }
        guard let list = try? await OrcaCLIBridge.shared.worktrees() else { return false }
        orcaWorktrees = list
        return true
    }

    /// Start a fresh Claude Code session in `worktreePath` and hand `prompt` to
    /// it. Returns false when Orca is missing, the create failed, the agent
    /// never came up, or the prompt wasn't accepted — the caller must not
    /// pretend any of those sent.
    ///
    /// The new session announces itself through the usual SessionStart hook a
    /// moment later, so it joins `claudeSessions` on its own; we only cache the
    /// handle so the send path can reach it before that lands.
    func startClaudeSession(in worktreePath: String, prompt: String?) async -> Bool {
        guard OrcaCLIBridge.isInstalled else { return false }
        do {
            let handle = try await OrcaCLIBridge.shared.createTerminal(
                worktreePath: worktreePath, command: "claude"
            )
            // Bring the new tab forward ourselves rather than making `create`
            // block on the UI adopting it (see createTerminal's note).
            activateOrcaApp()
            try? await OrcaCLIBridge.shared.focus(handle: handle)
            guard await OrcaCLIBridge.shared.waitForAgent(handle: handle) else { return false }
            guard let prompt, !prompt.isEmpty else { return true }
            return (try? await OrcaCLIBridge.shared.send(handle: handle, text: prompt)) ?? false
        } catch {
            return false
        }
    }

    // MARK: - Process scan (sessions that predate us)

    private var lastScanAt: Date = .distantPast
    private var scanInFlight = false

    /// Orca pane per scanned pid, so a jump can land on the right terminal.
    /// Keyed by pid rather than sessionId because the scanned session has no
    /// session id yet — and the pid survives adoption. Not @Published:
    /// nothing renders from it, it only feeds the jump.
    private var orcaPaneByPid: [Int32: String] = [:]

    /// Look for Claude Code processes that were already running at launch.
    /// Sessions opened after us announce themselves over the hook, so this
    /// only exists to cover the ones that started first.
    func scanForRunningClaudeSessions() {
        guard !scanInFlight else { return }
        // The view re-asks every couple of seconds while the card is on screen;
        // a rescan shells out, so rate-limit it well below that.
        guard Date().timeIntervalSince(lastScanAt) > 30 else { return }
        scanInFlight = true
        lastScanAt = .now
        Task.detached(priority: .utility) { [weak self] in
            let found = ClaudeProcessScanner.scan()
            await MainActor.run { self?.applyScan(found) }
        }
    }

    private func applyScan(_ found: [ScannedClaudeProcess]) {
        scanInFlight = false
        let live = Set(found.map(\.pid))
        // A process that has since died shouldn't linger as a card.
        claudeSessions.removeAll { $0.provisional && ($0.pid.map { !live.contains($0) } ?? true) }
        for p in found where !claudeSessions.contains(where: { $0.pid == p.pid }) {
            if let key = p.paneKey { orcaPaneByPid[p.pid] = key }
            // Holding ORCA_PANE_KEY *is* the evidence that Orca spawned this
            // process, so a scanned Orca session has a known host even though
            // no hook has ever reported one. Otherwise fall back to whatever
            // the parent chain says (Terminal.app, VS Code, …).
            let hostApp = p.paneKey != nil ? ClaudeHost.orcaBundleId : p.hostBundleId

            // Claude's registry knows the cwd, the name and whether the agent
            // is busy; prefer those over what the process table could tell us.
            let cwd = p.descriptor?.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? p.cwd
            let raw = URL(fileURLWithPath: cwd).lastPathComponent
            let projectName = HookServer.aliasProjectName(raw.isEmpty ? "Claude" : raw)

            if let d = p.descriptor, let sid = d.sessionId, !sid.isEmpty, !ClaudeSession.isProvisionalId(sid) {
                claudeSessions.insert(
                    .scanned(sessionId: sid, pid: p.pid, cwd: cwd,
                              projectName: projectName,
                              sessionName: d.name ?? "",
                              phase: Self.phase(forClaudeStatus: d.status),
                              startedAt: d.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now,
                              hostApp: hostApp),
                    at: 0
                )
                appendAppLog("nb.log", "scan: pid=\(p.pid) sid=\(sid) cwd=\(cwd) status=\(d.status ?? "?")")
            } else {
                // No registry entry — an older Claude Code, or the file wasn't
                // readable. Fall back to a placeholder that a hook will adopt.
                claudeSessions.insert(
                    .provisional(pid: p.pid, cwd: cwd, projectName: projectName, hostApp: hostApp),
                    at: 0
                )
                appendAppLog("nb.log", "scan: pid=\(p.pid) cwd=\(cwd) (provisional)")
            }
        }
    }

    /// Claude's `status` → our visual phase. "busy" means the agent is working;
    /// anything else (notably "idle", the common state — sitting at the prompt
    /// waiting for you) renders as the dim stopped dot rather than green, which
    /// would wrongly read as "look, it just finished something".
    private static func phase(forClaudeStatus status: String?) -> SessionPhase {
        status == "busy" ? .working : .stopped
    }

    /// True while the session's agent process is still running.
    ///
    /// Signal 0 makes `kill` do its permission / existence check only — it never
    /// signals the process. `EPERM` (pid exists, owned by someone else) still
    /// means alive; only `ESRCH` (no such process) means dead.
    func isClaudeSessionAlive(_ session: ClaudeSession) -> Bool {
        guard let pid = session.pid, pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Drop sessions whose agent process is gone. Called on a timer while the
    /// overview is on screen, because nothing else re-renders the list when a
    /// process dies — the last hook event already came in minutes ago.
    func pruneDeadClaudeSessions() {
        let dead = claudeSessions.filter { $0.pid != nil && !isClaudeSessionAlive($0) }
        guard !dead.isEmpty else { return }
        for s in dead {
            claudeSessions.removeById(s.sessionId)
            claudeSessionSteps[s.sessionId] = nil
            clearSessionDiffs(for: s.sessionId)
            if focusedSessionId == s.sessionId { focusedSessionId = nil }
        }
    }

    /// Mark a session as "stop monitoring": drop it from the right-side list
    /// and keep future hook events from re-adding it. Persists across restarts.
    ///
    /// The session itself is kept in `hiddenClaudeSessions`. Hiding used to
    /// discard everything but the id, which left `unhideClaudeSession` with
    /// nothing to put back — resuming only cleared the blacklist and the card
    /// stayed gone until some later hook event happened to re-add it, which for
    /// an idle session could be hours, and for a dead one never happened.
    func hideClaudeSession(_ sessionId: String) {
        if let idx = claudeSessions.firstIndex(where: { $0.sessionId == sessionId }) {
            hiddenClaudeSessions[sessionId] = claudeSessions[idx]
        }
        hiddenClaudeSessionIds.insert(sessionId)
        claudeSessions.removeById(sessionId)
        if focusedSessionId == sessionId { focusedSessionId = nil }
    }

    /// Reverse of `hideClaudeSession`. Puts the session back immediately when we
    /// still have it, rather than waiting for the next hook event or scan.
    ///
    /// If its process is gone by now, it comes back marked `.stopped` — still
    /// listed, because the user asked for it back, but not claiming to be
    /// running. With no snapshot (hidden in an earlier session, before the
    /// snapshot existed) there is nothing to restore and the id simply leaves
    /// the blacklist; the process scan will pick the session up if it's alive.
    func unhideClaudeSession(_ sessionId: String) {
        hiddenClaudeSessionIds.remove(sessionId)
        guard let saved = hiddenClaudeSessions.removeValue(forKey: sessionId) else { return }
        var s = saved
        if let pid = s.pid, !isClaudeSessionAlive(s) { s.state = .stopped }
        claudeSessions.upsert(
            sessionId: s.sessionId, cwd: s.cwd, hostApp: s.hostApp,
            sessionBundleId: s.sessionBundleId, projectName: s.projectName,
            phase: s.state, eventTime: .now, pid: s.pid
        )
        // Carry the colour and outfit across too — a re-scan would pick new
        // ones, so resuming and restarting would otherwise restyle the Mochi.
        let idx = claudeSessions.firstIndex { $0.sessionId == s.sessionId }
        if let idx {
            claudeSessions[idx].bodyColor = s.bodyColor
            claudeSessions[idx].outfit = s.outfit
            claudeSessions[idx].customName = s.customName
            claudeSessions[idx].sessionName = s.sessionName
            claudeSessions[idx].scanned = s.scanned
        }
    }

    /// Remove a Claude Code session by id. No-op if absent. Does NOT touch tasks/focus.
    func removeClaudeSession(sessionId: String) {
        claudeSessions.removeById(sessionId)
        // Its diffs were filed under the session id, so they go with it. Without
        // this they would only fall out via the idle timer, an hour later.
        clearSessionDiffs(for: sessionId)
    }

    /// Set the outfit (hat / glasses / scarf / …) for a Claude session.
    /// Drives both the right-side pill avatar and the main Mochi when this
    /// session is the active `overviewSession`. Lets the user dress each
    /// session individually from the overview's right card.
    func setSessionOutfit(_ sessionId: String, _ outfit: Outfit) {
        guard let idx = claudeSessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        claudeSessions[idx].outfit = outfit
    }

    /// Set the body colour for a Claude session's Mochi, from the wardrobe's
    /// swatch row. Drives both the right-side pill avatar and the main Mochi
    /// while this session is the active `overviewSession`.
    func setSessionBodyColor(_ sessionId: String, _ hex: String) {
        guard let idx = claudeSessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        claudeSessions[idx].bodyColor = hex
    }

    /// Set the name shown on the home view for a Claude session, from the
    /// wardrobe. Empty restores the project folder's name.
    func setSessionName(_ sessionId: String, _ name: String) {
        guard let idx = claudeSessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        claudeSessions[idx].customName = name
    }

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

    func setPillBadge(_ badge: PillBadge, for id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].pillBadge = badge
    }

    // MARK: - Session history reload (JSONL)
    //
    // The hook pipe only sees events that happen *after* Coucou started. To show
    // the full session (including pre-Coucou prompts/responses) we read Claude
    // Code's own `~/.claude/projects/.../<sessionId>.jsonl` log on demand.
    //
    // For agents without a JSONL file (Cursor, Codex, Resend, …) this is a no-op;
    // their history still arrives via HookServer.appendHistory.

    private var reloadWorkItems: [String: DispatchWorkItem] = [:]

    /// Coalesce rapid events: cancel any pending reload for this task and schedule
    /// a new one 100 ms later. Called by HookServer after each event.
    @MainActor
    func scheduleReloadHistoryFromJSONL(for taskId: String) {
        reloadWorkItems[taskId]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reloadHistoryFromJSONL(for: taskId)
        }
        reloadWorkItems[taskId] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    /// Read the JSONL and replace `tasks[idx].history` wholesale. The reassign
    /// at the end forces `@Published` to fire — mutating a struct field inside
    /// an array doesn't always trigger SwiftUI re-render on its own.
    @MainActor
    func reloadHistoryFromJSONL(for taskId: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let url: URL?
        if let cwd = tasks[idx].sessionCwd, let sid = tasks[idx].sessionId {
            url = SessionHistoryLoader.jsonlURL(cwd: cwd, sessionId: sid)
        } else if let cwd = tasks[idx].sessionCwd {
            url = SessionHistoryLoader.mostRecentSessionURL(cwd: cwd)
        } else {
            // No cwd and no session id: nothing identifies which transcript
            // belongs to this task. The old fallback took the newest .jsonl
            // under ~/.claude and filed it here, which attributes an unrelated
            // past session to whatever agent this pill is showing.
            url = nil
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let entries = SessionHistoryLoader.loadHistory(from: url)
        tasks[idx].history = entries
        tasks[idx] = tasks[idx]  // force @Published to detect the change
        appendAppLog("nb.log", "reloadJSONL \(taskId) → \(entries.count) entries from \(url.lastPathComponent)")
    }


    func syncMode() {
        // If no tasks and not expanded/peek, go hidden
        if tasks.isEmpty && mode == .compact {
            mode = .hidden
        } else if !tasks.isEmpty && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Load all workspace + agent pills into tasks. Safe to call multiple times.
    func loadIntegrationTasks() {
        let catalog = PillCatalog.available
        // Validate mainPillId: must be a non-comingSoon workspace pill in the catalog
        if !PillCatalog.available.contains(where: { $0.id == mainPillId && $0.category == .workspace && !$0.comingSoon }) {
            mainPillId = PillCatalog.defaultMainPillId
        }
        for def in catalog {
            let loaded = tasks.contains(where: { $0.id == def.id })
            if !loaded {
                let task = AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: .idle, steps: [], source: def.source)
                tasks.append(task)
            }
        }
        sortTasksByCatalog()
        if focusId == nil { focusId = mainPillId }
        syncMode()
    }

    /// Toggle a catalog pill on/off.
    /// mainPillId: never toggleable (change via the Main picker first).

    /// Sort tasks so catalog pills are in catalog order, undeclared pills sit right after
    /// integration_claude (matching HookServer insertion behaviour), and the rest follows.
    private func sortTasksByCatalog() {
        let order = PillCatalog.available.enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let catalogPills    = tasks.filter { order[$0.id] != nil }
        let undeclaredPills = tasks.filter { order[$0.id] == nil }
        let sortedCatalog   = catalogPills.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        if let claudeIdx = sortedCatalog.firstIndex(where: { $0.id == "integration_claude" }) {
            var result: [AgentTask] = Array(sortedCatalog[...claudeIdx])
            result.append(contentsOf: undeclaredPills)
            if claudeIdx + 1 < sortedCatalog.count {
                result.append(contentsOf: sortedCatalog[(claudeIdx + 1)...])
            }
            tasks = result
        } else {
            tasks = undeclaredPills + sortedCatalog
        }
    }

}


struct SearchResult {
    var title: String
    var items: [ResultItem]
    var note: String?
}

struct ResultItem {
    var label: String
    var detail: String
    var url: String?
}

// MARK: - Vercel

// MARK: - Chat

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var content: String   // var for streaming updates

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }

    /// Map a parsed JSONL line into a chat message. `thinking` / `toolCall` /
    /// `system` lines render as assistant messages (left-aligned, markdown),
    /// since `ChatBubble` only distinguishes user vs assistant layout.
    init(parsedLineRole: String, content: String) {
        self.role = (parsedLineRole == "user") ? .user : .assistant
        self.content = content
    }
}
