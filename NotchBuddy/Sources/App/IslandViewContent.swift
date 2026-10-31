import SwiftUI

// MARK: - Dispatch view content by IslandView

struct IslandViewContent: View {
    let view: IslandView
    @ObservedObject var state: AppState

    var body: some View {
        switch view {
        // Nothing real is running (no live Claude session, and the permanent
        // integration_claude pill has no activity) — say so instead of
        // rendering a character for an agent that isn't there.
        case .overview:
            if state.hasOverviewContent { OverviewView(state: state) }
            else { EmptyStateView(state: state) }
        case .empty:     EmptyStateView(state: state)
        case .approval:  ApprovalView(state: state)
        case .question:  QuestionView(state: state)
        case .finished:  FinishedView(state: state)
        case .prompt:    PromptView(state: state)
        case .searching: SearchingView(state: state)
        case .result:    ResultView(state: state)
        case .note:      NoteView(state: state)
        case .greeting:  EmptyView()  // GreetingCanvasView overlaid in IslandRootView
        case .wardrobe:  WardrobeView(state: state)
        case .changes:  SessionChangesView(state: state)
        }
    }
}

// MARK: - Overview

/// Navigating to where an agent actually runs: Orca's exact terminal tab when
/// Orca hosts the session, otherwise raising the host app (VS Code, Cursor, a
/// terminal…). Shared by the overview card's ↗ button and each session pill's.
@MainActor
enum AgentLauncher {
    static func open(_ task: AgentTask?, state: AppState) {
        guard let task else { return }
        // Orca first: if Orca hosts this session, switch to its exact
        // terminal tab instead of merely raising the app.
        Task { @MainActor in
            if await state.jumpToOrcaTerminal(sessionId: task.sessionId) { return }
            activateHostApp(for: task, state: state)
        }
    }

    /// Fallback for when Orca doesn't host the session: raise the app that
    /// runs it (VS Code, Cursor, a terminal, …).
    private static func activateHostApp(for task: AgentTask, state: AppState) {
        switch task.id {
        case "integration_claude":
            if ClaudeHost.activate(task.hostApp) { return }
            // By bundle id, not by a hard-coded path: VS Code installed
            // anywhere else (~/Applications, a non-standard volume) was
            // silently not opened at all.
            AppActivation.activate(bundleId: "com.microsoft.VSCode")
        case "agent_cursor":
            #if !APPSTORE
            AppActivation.activate(bundleId: "com.todesktop.230313mzl4w4u92")
            #endif
        case "agent_codex":
            #if !APPSTORE
            AppActivation.activate(bundleId: "com.openai.codex")
            #endif
        case "agent_claude-desktop":
            openClaudeDesktopApp()
        case "agent_gemini", "agent_antigravity",
             "agent_copilot", "agent_muse", "agent_opencode", "agent_amp":
            #if !APPSTORE
            TerminalTarget.activate(sessionBundleId: nil)
            #endif
        default:
            #if !APPSTORE
            TerminalTarget.activate(sessionBundleId: task.sessionBundleId)
            #endif
        }
    }
}

/// Bring the user to the session's terminal: its Orca tab when Orca hosts it,
/// otherwise the app the session runs in, otherwise any known terminal,
/// otherwise Terminal.app. The jump only — the caller decides whether the
/// notification is acknowledged, since the finished card's button clears it
/// while a double-click on a waiting row must not.
func openTerminalForSession(task: AgentTask?, sessionId: String?, state: AppState) {
    #if !APPSTORE
    Task { @MainActor in
        // Orca hosts this session → jump to its exact tab. An empty id means
        // "the focused session", which is the same thing the ↗ pills do.
        let sid = sessionId.flatMap { $0.isEmpty ? nil : $0 }
        if await state.jumpToOrcaTerminal(sessionId: sid) { return }
        // Otherwise raise the app the session runs in (its terminal, or VS
        // Code), then any known terminal. A session that never fired a hook has
        // no workspace pill to read a host from — the scan named it on the
        // session — so fall back to asking the session itself.
        let hostBundleId = task?.sessionBundleId
            ?? sid.flatMap { state.hostBundleId(forSessionId: $0) }
            ?? task?.hostApp
        // The field is the signal, not the pill id: a session pill is
        // "claude:<id>" and would never match the id this used to test for,
        // even when it carries a perfectly good host.
        if !(task != nil && ClaudeHost.activate(task?.hostApp)),
           !TerminalTarget.activate(sessionBundleId: hostBundleId) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
    #endif
}

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var activeDiffId: Int? = nil

    /// Context-window usage of the session on the left card, or nil when it
    /// has not been through the statusline wrapper.
    ///
    /// Polled rather than pushed: the wrapper writes a file and nothing tells
    /// us when it changed, and the left card only ever shows one session, so
    /// reading the whole live-session list would be work nobody sees.
    @State private var contextWindow: ContextWindow? = nil

    /// Hover state for the host chip at the bottom of the left card.
    @State private var chipHovered = false

    /// The line under the session name: the source, and how full the session's
    /// context window is.
    ///
    /// Its own view rather than inline: this card's `body` was already at the
    /// edge of what the type-checker will accept in one expression, and adding
    /// a nested `Text` with a `switch` over the source tipped it over.
    private func sourceRow(_ source: AgentSource,
                           contextWindow: ContextWindow?) -> some View {
        HStack(spacing: 6) {
            // "Claude Code" on every Claude session, and this card only ever
            // renders Claude work — a constant that says nothing. The other
            // sources are worth the space.
            if source != .claudeCode {
                Text({ () -> String in
                    switch source {
                    case .claudeCode: return "Claude Code"
                    case .agent:      return "Agent"
                    case .n8n:        return "n8n"
                    }
                }())
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Absent until the session has been through the statusline
            // wrapper — see ContextBar.
            if let window = contextWindow {
                ContextBar(window: window)
            }
        }
        // Its own trailing inset, and it does not widen when the diff capsule
        // appears: that capsule and the ↗ button sit above this line, not
        // beside it. Sharing the title row's inset left 44pt here on sessions
        // that had edited something — too narrow for anything readable.
        .padding(.trailing, 12)
    }

    /// Open the changes list for whatever session the left card is showing.
    /// Needs a session to key on: a card showing an agent with no Claude
    /// session behind it has no diffs of its own, so there is nothing to show
    /// and the tap is left alone rather than opening an empty list.
    private func openChangesForOverview() {
        guard let s = state.overviewSession else { return }
        state.focusedSessionId = s.sessionId
        state.view = .changes
    }

    /// Left card shows the most-recently-active Claude session when there is
    /// one. Falls back to the focus task for the no-Claude-session case.
    var agent: AgentTask? {
        if let s = state.overviewSession { return state.overviewTask(for: s) }
        return state.focusTask
    }

    /// Whether this card's session has changed any file. Single source for
    /// "show the capsule" and "make room for it" — two separate conditions
    /// would drift, and the failure is silent: a name truncated by a space
    /// nothing occupies.
    private var hasChangeTotals: Bool {
        guard let sid = agent?.sessionId else { return false }
        return !state.fileChanges(for: sid).isEmpty
    }

    /// The bottom of the left card: ↗ plus the app the session runs in, both
    /// leading to the same place — the terminal — and trailing-aligned like the
    /// chat card's pair, so jumping to a session reads the same from either
    /// page. Nothing for a card with no session behind it: there is no terminal
    /// to reach and no host to name.
    ///
    /// Its own view, not inline: `body` was already at the edge of what the
    /// type-checker accepts in one expression, and these two buttons tipped it
    /// over.
    @ViewBuilder
    private var jumpAndHostRow: some View {
        if let session = state.overviewSession {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                // The chip names where the session runs, so it *is* the jump —
                // no arrow beside it, like the chat card.
                Button(action: { AgentLauncher.open(agent, state: state) }) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: session.bodyColor))
                            .frame(width: 6, height: 6)
                        Text(ClaudeHost.label(for: session))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color(hex: "#7B8089"))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(chipHovered ? 0.12 : 0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { chipHovered = $0 }
                .help(String(localized: "Open terminal"))
            }
            .padding(.leading, 108)
            .padding(.trailing, 12)
            .padding(.bottom, 4)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Left card: title row + ticker below + the ↗ / host chip row
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)

                // Title row + ticker stacked
                if let agent = agent {
                    VStack(alignment: .leading, spacing: 0) {
                        // Two lines: the name, the source under it. Sharing one
                        // line meant the source lost — "Claude Code" came out as
                        // "Claude C…" on every session whose name was more than
                        // a few characters.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                // No status dot beside the name. The Mochi beside
                                // this row already carries one — BotEngine's badge,
                                // three pulsing dots while working, a single dot
                                // when finished or idle. This one repeated the same
                                // state in a second place, and the two could even
                                // disagree: the badge follows `mainMochiState`,
                                // this followed `agent.state`.
                                Text(agent.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(hex: "#F5F6F8"))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                Spacer(minLength: 2)
                            }
                            // Only this row shares vertical space with the diff
                            // capsule, so only this row reserves room for it. A
                            // fixed wide value on the whole stack would shorten the
                            // session name even on sessions that have never touched
                            // a file, for a badge that is not there.
                            .padding(.trailing, hasChangeTotals ? 70 : 12)
                            sourceRow(agent.source, contextWindow: contextWindow)
                        }
                        .padding(.top, 6)
                        .padding(.leading, 108)

                        TickerView(task: agent, onDiffTap: { diffIdx in
                            withAnimation(.easeIn(duration: 0.16)) { activeDiffId = diffIdx }
                        })
                            // Breathing room between the title and the step
                            // below it. The ticker sizes itself to its text, so
                            // this is the only thing setting that gap.
                            .padding(.top, 0)
                            .padding(.leading, 108)
                            .padding(.trailing, 12)

                        // ↗ + the app the session runs in, bottom-right — the
                        // same pair the chat card closes with, so "go to the
                        // terminal" reads the same from either page and the
                        // name beside it says where that is.
                        jumpAndHostRow
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
                }

                // Diff overlay — replaces ticker when a diff step is tapped.
                // Look the diff up by the session it belongs to: `agent.id` is
                // a per-session synthetic id ("claude:<uuid>") while diffs are
                // filed under the real session id, so keying on task.id found
                // nothing and the card never opened.
                if let diffId = activeDiffId,
                   let diff = state.diff(id: diffId, in: agent?.sessionId ?? state.focusedSessionId) {
                    CardBackground(wash: nil)
                    DiffCardView(diff: diff, onDismiss: { activeDiffId = nil })
                        .transition(.opacity)
                }

                // Diff capsule — last in ZStack so it renders on top; hidden
                // while a diff is open. A Button, not part of the card's tap
                // gesture: a Button's gesture wins over the ancestor's, so it
                // is clickable without also opening the chat.
                let hideChangeCapsule = activeDiffId != nil
                if !hideChangeCapsule {
                    HStack(spacing: 4) {
                        // The session's running totals, as the way in to its
                        // changes — the numbers say what changed and the
                        // capsule says it opens something. Shown only once the
                        // session has actually touched a file; until then it
                        // could only open an empty list.
                        if hasChangeTotals, let sid = agent?.sessionId {
                            let totals = state.changeTotals(for: sid)
                            Button(action: { openChangesForOverview() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(Color(hex: "#5F646D"))
                                    if totals.added > 0 {
                                        Text("+\(totals.added)")
                                            .font(.system(size: 9, weight: .medium).monospaced())
                                            .foregroundColor(Color(hex: "#22C55E"))
                                    }
                                    if totals.removed > 0 {
                                        Text("−\(totals.removed)")
                                            .font(.system(size: 9, weight: .medium).monospaced())
                                            .foregroundColor(Color(hex: "#F4505E"))
                                    }
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Color.white.opacity(0.07))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Files this session changed"))
                            // Right-click resets, so a fresh count is one move
                            // away without entering the list first. Context menu
                            // rather than a second button: two controls on a
                            // card this size start colliding with the name.
                            .contextMenu {
                                Button {
                                    state.clearSessionDiffs(for: sid)
                                } label: {
                                    Label(String(localized: "Reset the counts"),
                                          systemImage: "arrow.counterclockwise")
                                }
                                .disabled(!hasChangeTotals)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 322)
            .contentShape(Rectangle())
            .onTapGesture {
                // The whole card is the way into the chat, for whatever session
                // it is currently showing — i.e. the one last picked in the
                // right-hand list. What the session changed is one click away,
                // on the Diff capsule at the top-right.
                if let s = state.overviewSession {
                    // Lock the chat to the card's session so its host shows in
                    // the bottom-right label (e.g. "Orca") instead of falling
                    // back to the global tasks[].
                    state.focusedSessionId = s.sessionId
                    state.view = .prompt
                } else if let task = state.focusTask,
                          PillCatalog.isChatablePill(id: task.id) {
                    state.view = .prompt
                }
            }

            // Right card: agent pills
            CardBackground(wash: nil) {
                ClaudeSessionsListView(state: state)
            }
        }
        // Air above and below both cards. The cards sit flush against the
        // icon row above them and the window edge below (the island stacks
        // header + content with no spacing), so the text inside read as
        // crowded against the chrome. The height budget pays for this:
        // TickerView.currentLines gives back what these two add.
        .padding(.vertical, 6)
        .onChange(of: state.focusId) { _, _ in
            activeDiffId = nil
        }
        .onChange(of: state.view) { _, v in
            if v != .overview { activeDiffId = nil }
        }
        .onChange(of: state.mode) { _, m in
            if m != .expanded { activeDiffId = nil }
        }
        // Left card can start showing a different session without focusId
        // changing (the overview falls back to claudeSessions.first), which
        // would leave an activeDiffId belonging to the previous one.
        .onChange(of: agent?.sessionId) { _, _ in
            activeDiffId = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandToggleDiff)) { _ in
            if let id = activeDiffId {
                withAnimation(.easeIn(duration: 0.16)) { activeDiffId = nil }
                _ = id
            } else if let key = agent?.sessionId ?? state.focusedSessionId ?? state.focusTask?.sessionId,
                      let last = state.diffs(for: key).last {
                withAnimation(.easeIn(duration: 0.16)) { activeDiffId = last.id }
            }
        }
        // Re-read the payload for whatever session the card is showing. Keyed
        // on the id so switching sessions restarts against the right file, and
        // cancelled with the view, so a hidden island costs nothing.
        .task(id: agent?.sessionId) { await pollContextWindow() }
    }

    /// Follows the statusline payload for the card's current session until the
    /// view goes away. Two seconds is well inside how often Claude Code
    /// redraws a statusline, and finer would only cost wakeups.
    private func pollContextWindow() async {
        while !Task.isCancelled {
            var window: ContextWindow?
            if let sid = agent?.sessionId {
                window = await Task.detached { StatusLineReader.contextWindow(sessionId: sid) }.value
            }
            if contextWindow != window { contextWindow = window }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

// MARK: - Context bar

/// How full a session's context window is: a horizontal bar with the
/// percentage and the token counts beside it.
///
/// The bar carries the shape, the numbers carry the precision. The bar alone
/// is unreadable past its first two steps; the numbers alone need the bar to
/// be comparable against the last session without reading them.
private struct ContextBar: View {
    var window: ContextWindow

    /// Product thresholds, not Claude Code's: auto-compact lands around 80%
    /// on a 200k window and ~97% on a 1M one, so no single fraction means
    /// "about to compact". Amber is worth a look; red is "this one is nearly
    /// full", which on a 1M session arrives long before anything is lost.
    private static let warning: Double = 0.70
    private static let critical: Double = 0.85

    /// Wide enough to read a fraction off, short enough to leave room for the
    /// counts: measured, this line is 189pt of text plus the bar inside a
    /// 202pt inset, so 50pt is what is actually free.
    private static let barWidth: CGFloat = 50

    private var percent: Int { Int((window.usedFraction * 100).rounded()) }
    private var usedTokens: Int { Int((window.usedFraction * Double(window.windowSize)).rounded()) }

    var body: some View {
        HStack(spacing: 6) {
            Text(String(localized: "context.label"))
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#6B7079"))

            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: "#454850")).frame(height: 5)
                Capsule().fill(fillColor)
                    .frame(width: max(Self.barWidth * window.usedFraction, 2), height: 5)
            }
            .frame(width: Self.barWidth, height: 5)

            Text("\(percent)%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(fillColor)

            Text("(\(Self.format(usedTokens))/\(Self.format(window.windowSize)))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(Color(hex: "#6B7079"))

            Spacer(minLength: 0)
        }
    }

    private var fillColor: Color {
        if window.usedFraction >= Self.critical { return Color(hex: "#F4505E") }
        if window.usedFraction >= Self.warning { return Color(hex: "#F5A524") }
        return Color(hex: "#8E939C")
    }

    /// 189k, 1.0M, 200K — the same shape claude-hud uses, so the two do not
    /// disagree about the same number.
    static func format(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 10_000 { return "\(tokens / 1000)k" }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1000) }
        return "\(tokens)"
    }
}

// MARK: - Empty

struct EmptyStateView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            if state.showProjectPicker {
                // The list takes the card over — same panel the + opens on the
                // home page, so there is one place that looks like this.
                // The leading gap is Mochi's lane, same as the copy below: he
                // is drawn at this view's botX, and a full-width panel ran
                // the first row straight through his face.
                OrcaProjectPickerList(state: state,
                                      isPresented: $state.showProjectPicker,
                                      onStarted: { wt, began in
                    Task { @MainActor in
                        guard await state.focusClaudeSessionStarted(inCwd: wt.path,
                                                                    since: began) != nil else { return }
                        state.view = .prompt
                    }
                })
                .padding(.leading, IslandConst.mochiLaneWidth)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .transition(.opacity)
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Nothing running right now.")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Drop a file or window, or ask me anything.")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#9398A1"))
                    }
                    Spacer()
                    // Nothing to ask until there is an agent to ask, and the
                    // chat can't start one any more — so this button is the
                    // list.
                    PrimaryButton("Ask Claude") {
                        state.showProjectPicker = true
                        Task { await state.loadOrcaWorktrees() }
                    }
                }
                .padding(.leading, IslandConst.mochiLaneWidth)
                .padding(.trailing, 18)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: state.showProjectPicker)
    }
}

// MARK: - Approval

struct ApprovalView: View {
    @ObservedObject var state: AppState

    var approval: ApprovalInfo? { state.pendingApproval }

    var body: some View {
        ZStack {
            CardBackground(wash: .amber)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask,
                         name: state.sessionName(for: state.pendingApproval?.sessionId),
                         label: "needs permission")
                CodeBlock(text: approval?.command ?? approval?.tool ?? "…")
                ApprovalDecisionButtons(info: approval) {
                    HookServer.shared.sendApprovalDecision($0)
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Deny / Allow / Always, shared by the detail card and the inbox row so the
/// two can't drift. `onDecision` receives "deny", "allow" or "always".
private struct ApprovalDecisionButtons: View {
    let info: ApprovalInfo?
    let onDecision: (String) -> Void

    /// Codex, Copilot CLI and Muse Code do not support updatedPermissions.
    private var hideAlways: Bool {
        guard let pillId = info?.pillId else { return false }
        return pillId == "agent_codex" || pillId == "agent_copilot" || pillId == "agent_muse"
    }

    var body: some View {
        HStack(spacing: 8) {
            SecondaryButton("Deny") { onDecision("deny") }
            PrimaryButton("Allow") { onDecision("allow") }
            if !hideAlways {
                SecondaryButton("Always") { onDecision("always") }
            }
        }
    }
}

// MARK: - Question

struct QuestionView: View {
    @ObservedObject var state: AppState
    @State private var questionIndex = 0
    // Per-question selected labels (empty = none chosen yet)
    @State private var selections: [[String]] = []
    // Per-question custom "Other…" text
    @State private var otherTexts: [String] = []
    // Per-question "Other…" mode active
    @State private var showOther: [Bool] = []
    @FocusState private var otherFieldFocused: Bool

    var question: AskQuestion? { state.pendingQuestion }

    var body: some View {
        ZStack {
            CardBackground(wash: .cyan)
            if let q = question, !q.questions.isEmpty {
                let qi = min(questionIndex, q.questions.count - 1)
                let item = q.questions[qi]
                let isLast = qi == q.questions.count - 1
                let isMulti = item.multiSelect
                let curSel = qi < selections.count ? selections[qi] : []
                let curOther = qi < showOther.count ? showOther[qi] : false
                let curOtherText = qi < otherTexts.count ? otherTexts[qi] : ""
                let canProceed = !curSel.isEmpty || (curOther && !curOtherText.isEmpty)

                VStack(alignment: .leading, spacing: 4) {
                    // Header row: agent name + question counter
                    HStack(spacing: 4) {
                        AgentWho(task: nil,
                                 name: state.sessionName(for: state.pendingQuestions.first?.sessionId),
                                 label: "Is asking")
                        Spacer(minLength: 4)
                        if q.questions.count > 1 {
                            Text("\(qi + 1)/\(q.questions.count)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#6B7079"))
                        }
                        // Handing back lives on the navigation row's Cancel,
                        // and on the inbox row's "Send back" — a third copy in
                        // the header did the same thing three times over.
                    }
                    // Optional short header label above question text
                    if !item.header.isEmpty {
                        Text(item.header)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    Text(item.question)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .fixedSize(horizontal: false, vertical: true)
                    // Options (wrapping) or "Other…" compact inline row
                    if curOther {
                        HStack(spacing: 6) {
                            TextField("Your answer…", text: Binding(
                                get: { qi < otherTexts.count ? otherTexts[qi] : "" },
                                set: { v in if qi < otherTexts.count { otherTexts[qi] = v } }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .focused($otherFieldFocused)
                            .onAppear { otherFieldFocused = true }
                            .onSubmit { commitOtherAndAdvance(qi: qi, isLast: isLast) }
                            .onExitCommand { if qi < showOther.count { showOther[qi] = false } }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button(isLast ? "Send" : "Next") {
                                commitOtherAndAdvance(qi: qi, isLast: isLast)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(curOtherText.isEmpty ? Color(hex: "#6B7079") : Color(hex: "#F5F6F8"))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(curOtherText.isEmpty ? 0.05 : 0.15))
                            .clipShape(Capsule())
                            .disabled(curOtherText.isEmpty)
                            Button { if qi < showOther.count { showOther[qi] = false } } label: {
                                Text("✕").font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(Color(hex: "#6B7079"))
                        }
                    } else if item.hasDescriptions {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { idx, opt in
                                let isSelected = curSel.contains(opt.label)
                                Button {
                                    if isMulti {
                                        toggleSelection(qi: qi, label: opt.label)
                                    } else {
                                        selectAndAdvance(q: q, qi: qi, label: opt.label, isLast: isLast)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(opt.label)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(isSelected ? Color(hex: "#67E8F9") : Color(hex: "#F5F6F8"))
                                        if !opt.description.isEmpty {
                                            Text(opt.description)
                                                .font(.system(size: 11))
                                                .foregroundColor(Color(hex: "#9AA0A8"))
                                                .multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(isSelected ? Color(hex: "#22D3EE").opacity(0.22) : Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color(hex: "#22D3EE").opacity(0.55) : Color.white.opacity(0.1), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [])
                            }
                            SecondaryButton("Other…") {
                                if qi < showOther.count { showOther[qi] = true }
                            }
                        }
                    } else {
                        ChipFlowLayout(spacing: 6) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { idx, opt in
                                let isSelected = curSel.contains(opt.label)
                                if isMulti {
                                    Button {
                                        toggleSelection(qi: qi, label: opt.label)
                                    } label: {
                                        Text(opt.label)
                                            .font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(isSelected ? Color(hex: "#22D3EE").opacity(0.22) : Color.white.opacity(0.07))
                                            .foregroundColor(isSelected ? Color(hex: "#67E8F9") : Color(hex: "#C5C8CD"))
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Color(hex: "#22D3EE").opacity(0.55) : Color.white.opacity(0.1), lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [])
                                } else {
                                    SecondaryButton(verbatim: opt.label) {
                                        selectAndAdvance(q: q, qi: qi, label: opt.label, isLast: isLast)
                                    }
                                    .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [])
                                }
                            }
                            // "Other…" implicit free-text option
                            SecondaryButton("Other…") {
                                if qi < showOther.count { showOther[qi] = true }
                            }
                        }
                    }
                    // Navigation. Picking an option only selects it — the card
                    // used to submit the moment a single-select answer was
                    // clicked, which left no way back and no way to change it.
                    if !curOther {
                        // Back is navigation, so it stays on its own at the far
                        // left; Back to Terminal and the primary action sit
                        // together on the right, on every question — bailing out
                        // to the terminal must not require reaching the last one.
                        HStack(spacing: 8) {
                            SecondaryButton("Back") {
                                withAnimation { questionIndex = qi - 1 }
                            }
                            .disabled(qi == 0)
                            .opacity(qi == 0 ? 0.4 : 1)
                            Spacer(minLength: 0)
                            SecondaryButton("Back to Terminal") { HookServer.shared.sendQuestionAsk() }
                            PrimaryButton(isLast ? "Submit" : "Next") {
                                if isLast { sendAnswers(q: q) }
                                else { withAnimation { questionIndex = qi + 1 } }
                            }
                            .disabled(!canProceed)
                            .opacity(canProceed ? 1 : 0.4)
                        }
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { resetQuestionState() }
        .onChange(of: state.pendingQuestion) { _, _ in resetQuestionState() }
        .onDisappear { HookServer.shared.releaseQuestionFD() }
    }

    private func resetQuestionState() {
        questionIndex = 0
        let count = state.pendingQuestion?.questions.count ?? 0
        selections = Array(repeating: [], count: count)
        otherTexts = Array(repeating: "", count: count)
        showOther  = Array(repeating: false, count: count)
    }

    private func toggleSelection(qi: Int, label: String) {
        guard qi < selections.count else { return }
        if let i = selections[qi].firstIndex(of: label) {
            selections[qi].remove(at: i)
        } else {
            selections[qi].append(label)
        }
    }

    // Single-select: pick a label and immediately advance/send
    /// Pick a single-select answer and move on. The last question stops here
    /// so its Submit is a deliberate act rather than the third click in a row.
    private func selectAndAdvance(q: AskQuestion, qi: Int, label: String, isLast: Bool) {
        guard qi < selections.count else { return }
        selections[qi] = [label]
        if !isLast { withAnimation { questionIndex = qi + 1 } }
    }

    // "Other…" confirm
    /// Typed "Other…" answer: commit it and move on, same as picking a chip.
    /// Stops on the last question, where Submit waits.
    private func commitOtherAndAdvance(qi: Int, isLast: Bool) {
        let text = qi < otherTexts.count ? otherTexts[qi] : ""
        guard !text.isEmpty else { return }
        if qi < selections.count { selections[qi] = [text] }
        if qi < showOther.count { showOther[qi] = false }
        if !isLast { withAnimation { questionIndex = qi + 1 } }
    }

    private func sendAnswers(q: AskQuestion) {
        let answers = AskQuestion.buildAnswers(questions: q.questions, selections: selections)
        HookServer.shared.sendQuestionAnswers(answers)
    }
}

/// Brings the Claude desktop app forward (or launches it) — target of the Claude Desktop pill.
private let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

private func openClaudeDesktopApp() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeDesktopBundleId) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}

// MARK: - Finished

/// The island's inbox: everything waiting on the user, questions and
/// permissions first (they hold a hook open on a clock), finished sessions
/// after. Each row stands on its own — its own Mochi, its own text, its own
/// buttons — so several sessions at once never overwrite one shared slot.
struct FinishedView: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Reachable from the bell tab too, so it has to stand on its own when
        // there is nothing waiting.
        if state.inbox.isEmpty {
            EmptyNotificationsView()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: NotificationLayout.cardSpacing) {
                    ForEach(state.inbox) { item in
                        switch item {
                        case .finished(let n): FinishedCard(notification: n, state: state)
                        case .question(let q):  QuestionInboxCard(question: q, state: state)
                        case .approval(let a):  ApprovalInboxCard(approval: a, state: state)
                        }
                    }
                }
                .padding(.vertical, NotificationLayout.listPadding)
            }
        }
    }
}

// MARK: - Inbox rows that hold a hook open

/// A question waiting for an answer. Opens the full question UI rather than
/// trying to squeeze options into a row — that view pages multi-part questions,
/// has multi-select and a typed "Other…", and needs the whole card.
private struct QuestionInboxCard: View {
    let question: PendingQuestion
    @ObservedObject var state: AppState

    private var task: AgentTask? {
        state.tasks.first { $0.id == question.pillId } ?? state.focusTask
    }

    var body: some View {
        InboxRow(state: state, pillId: question.pillId, sessionId: question.sessionId, botState: .question,
                 onDoubleTap: { openTerminalForSession(task: task, sessionId: question.sessionId, state: state) },
                 wash: nil) {
            AgentWho(task: task,
                     name: state.sessionName(for: question.sessionId),
                     label: "Is asking")
            Text(question.question.questions.first?.question ?? String(localized: "Needs an answer"))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            InboxActions(
                deadline: question.deadline,
                openLabel: String(localized: "Answer"),
                onOpen: { HookServer.shared.openInboxItem(.question(question)) },
                onHandBack: { state.dismissInboxItem(.question(question)) }
            )
        }
    }
}

/// A permission request waiting to be allowed or denied. The row is the
/// approval card itself — amber wash, the command in a code block, the same
/// Deny / Allow / Always — so a request waiting in the list looks like the
/// thing that answers it, and nothing has to be opened first.
private struct ApprovalInboxCard: View {
    let approval: PendingApproval
    @ObservedObject var state: AppState

    private var task: AgentTask? {
        state.tasks.first { $0.id == approval.info.pillId } ?? state.focusTask
    }

    var body: some View {
        InboxRow(state: state, pillId: approval.info.pillId, sessionId: approval.info.sessionId, botState: .approval,
                 onDoubleTap: { openTerminalForSession(task: task, sessionId: approval.info.sessionId, state: state) },
                 wash: .amber) {
            AgentWho(task: task,
                     name: state.sessionName(for: approval.info.sessionId),
                     label: "needs permission")
            CodeBlock(text: approval.info.command)
            ApprovalDecisionButtons(info: approval.info) {
                HookServer.shared.answerApproval(id: approval.id, decision: $0)
            }
        }
    }
}

/// Shared chrome for the two blocking rows: the session's own Mochi on the
/// left, whatever the row says on the right. The finished card draws its own
/// bot, so it doesn't share this.
private struct InboxRow<Content: View>: View {
    let state: AppState
    let pillId: String
    let sessionId: String
    /// The state this row's Mochi wears. Passed in rather than derived from
    /// AppState, which is shared by every row on screen.
    let botState: BotState
    /// Double-click on the Mochi: take the user to the session's terminal.
    /// It leaves the request waiting — this only takes the user there and back.
    let onDoubleTap: () -> Void
    /// The colour wash behind the row. The permission row wears the same amber
    /// the approval card does, so a request waiting in the list looks like the
    /// card it answers.
    var wash: CardWash?
    @ViewBuilder let content: () -> Content

    /// 58pt Mochi vs the text beside it — the same size the finished card uses.
    private let botDiameter: CGFloat = 58

    private var session: ClaudeSession? {
        guard !sessionId.isEmpty else { return nil }
        return state.claudeSessions.first { $0.sessionId == sessionId }
    }

    var body: some View {
        CardBackground(wash: wash) {
            HStack(alignment: .center, spacing: 0) {
                BotCanvasView(state: state, sessionOverride: session, stateOverride: botState)
                    .frame(width: botDiameter / 0.6, height: botDiameter / 0.6)
                    .frame(width: botDiameter, height: botDiameter)
                    .padding(.leading, 28)
                    .padding(.trailing, 30)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onDoubleTap() }
                    // Right-click dresses *this* row's session. The wardrobe
                    // reads `state.overviewSession`, which follows
                    // `focusedSessionId`, so without binding first it would
                    // dress whichever session the island happens to be on.
                    .modifier(ContextMenuIf(enabled: session != nil) {
                        Button {
                            state.focusedSessionId = sessionId
                            state.view = .wardrobe
                        } label: {
                            Label(String(localized: "Change outfit…"), systemImage: "tshirt")
                        }
                    })

                VStack(alignment: .leading, spacing: 5) {
                    content()
                }
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Buttons plus the clock. The countdown is the point: a queued request runs
/// out and falls back to its terminal, and the row is the only place that says
/// how long is left.
private struct InboxActions: View {
    let deadline: Date
    let openLabel: String
    let onOpen: () -> Void
    let onHandBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PrimaryButton(openLabel, action: onOpen)
            SecondaryButton("Send back") { onHandBack() }
            Spacer(minLength: 4)
            DeadlineChip(deadline: deadline)
        }
    }
}

/// Applies a context menu only when there is one to show. A menu with nothing
/// in it still pops an empty panel on right-click, which reads as a broken row.
private struct ContextMenuIf<Menu: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let menu: () -> Menu

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu { menu() }
        } else {
            content
        }
    }
}

/// Seconds left before the island hands this request back to its agent.
private struct DeadlineChip: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let left = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            Text(left > 0 ? "\(left)s" : "handing back")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundColor(left <= 15 ? Color(hex: "#F4505E") : Color(hex: "#6B7079"))
        }
    }
}

private struct EmptyNotificationsView: View {
    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 5) {
                Text("Nothing has finished yet.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Sessions that finish will show up here.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#9398A1"))
            }
            .padding(.leading, 24)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FinishedCard: View {
    let notification: AgentNotification
    @ObservedObject var state: AppState

    private static let botDiameter: CGFloat = 58

    /// The task this notification's pill owns — used for the name, the colour
    /// dot and the fallback final line.
    private var task: AgentTask? {
        state.tasks.first { $0.id == notification.agentId } ?? state.focusTask
    }

    /// The session this card is about, so its Mochi wears that session's own
    /// body colour and outfit rather than the focused session's.
    private var session: ClaudeSession? {
        guard let sid = notification.sessionId, !sid.isEmpty else { return nil }
        return state.claudeSessions.first { $0.sessionId == sid }
    }

    private var finalLine: String {
        if !notification.finalLine.isEmpty { return notification.finalLine }
        if let fl = task?.finalLine, !isError { return fl }
        if let s = task?.steps.last(where: { !$0.isDiffStep }) { return s }
        return String(localized: isError ? "This turn didn't finish" : "Session finished")
    }

    /// Make this session drive the home view's left card, so wherever the user
    /// lands next they're on the session they were just told about, not
    /// whatever was focused before.
    private func focusSession() {
        if let sid = notification.sessionId, !sid.isEmpty {
            state.focusedSessionId = sid
        }
        state.setFocus(notification.agentId)
    }

    /// Drop just this card. The ones below close the gap; the island only goes
    /// home when the *whole* inbox is empty — a question still waiting keeps it
    /// on this page.
    private func acknowledge() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            state.dismissInboxItem(.finished(notification))
        }
    }

    private var isError: Bool { notification.kind == .error }

    /// The "Open terminal" button's whole action: bind the jump to *this*
    /// card's session — its sessionId is the one with a verified Orca handle
    /// binding, and without it we fall through to the focused session, which
    /// may be a different Claude session in the same worktree and lands on the
    /// wrong Orca tab — focus it, drop the card, then jump.
    private func openTerminalAndAcknowledge() {
        let task = task
        let sid = notification.sessionId
        focusSession()
        acknowledge()
        openTerminalForSession(task: task, sessionId: sid, state: state)
    }

    var body: some View {
        CardBackground(wash: isError ? .red : .green) {
            HStack(alignment: .center, spacing: 0) {
                BotCanvasView(state: state, sessionOverride: session,
                              stateOverride: isError ? .error : .finished)
                    .frame(width: Self.botDiameter / 0.6, height: Self.botDiameter / 0.6)
                    .frame(width: Self.botDiameter, height: Self.botDiameter)
                    .padding(.leading, 28)
                    .padding(.trailing, 30)
                    // Double-click jumps to the session's terminal. On a plain
                    // finished card that's the whole of the "Open terminal"
                    // button, so it clears the card too. A card that still
                    // needs something — a failure to look at — stays: the jump
                    // only takes the user there and back.
                    .onTapGesture(count: 2) {
                        if isError {
                            openTerminalForSession(task: task, sessionId: notification.sessionId, state: state)
                        } else {
                            openTerminalAndAcknowledge()
                        }
                    }

                VStack(alignment: .leading, spacing: 5) {
                    AgentWho(task: task,
                             name: session?.displayName,
                             label: isError
                             ? String(localized: "Turn stopped early")
                             : String(localized: "Turn finished"))
                    Text(finalLine)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 8) {
                        if task?.id == "agent_claude-desktop" {
                            // Sessions from the Claude desktop app live there, not in a terminal.
                            PrimaryButton("Open Claude") {
                                openClaudeDesktopApp()
                                NotificationCenter.default.post(name: .islandCollapse, object: nil)
                            }
                        } else {
                            #if !APPSTORE
                            PrimaryButton("Open terminal") {
                                openTerminalAndAcknowledge()
                            }
                            #endif
                        }
                        SecondaryButton("OK") {
                            focusSession()
                            acknowledge()
                        }
                    }
                }
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Diff Card

struct DiffCardView: View {
    let diff: FileDiff
    let onDismiss: () -> Void

    private var allLines: [DiffLine] { diff.hunks.flatMap { $0.lines } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Button(action: onDismiss) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .medium))
                        Text(diff.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(hex: "#F5F6F8"))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 2)
                if diff.added > 0 {
                    Text("+\(diff.added)")
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundColor(Color(hex: "#22C55E"))
                }
                if diff.removed > 0 {
                    Text("−\(diff.removed)")
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundColor(Color(hex: "#F4505E"))
                }
                Button(action: { openInEditor(diff) }) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(hex: "#5F646D"))
                        .frame(width: 14, height: 14)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
            .padding(.bottom, 3)

            // Content
            if diff.tooLarge {
                Text("Diff too large")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#6B7079"))
            } else if allLines.isEmpty {
                Text("No changes")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#6B7079"))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(allLines.enumerated()), id: \.offset) { _, line in
                            DiffLineRowView(line: line)
                        }
                    }
                }
            }
        }
        .padding(.leading, 108)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { onDismiss() }
    }

    private func openInEditor(_ diff: FileDiff) {
        let path = diff.path
        #if !APPSTORE
        let codePaths = ["/opt/homebrew/bin/code", "/usr/local/bin/code", "/usr/bin/code",
                         "\(NSHomeDirectory())/.nvm/current/bin/code"]
        if let codePath = codePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: codePath)
            // Write: open at line 1; Edit/MultiEdit: open file without line number
            p.arguments = diff.isNewFile ? ["-g", "\(path):1"] : [path]
            try? p.run()
            return
        }
        #endif
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - Per-session changes

/// The files one session edited, rolled up per file and most recent first.
/// Tapping a row opens that file's latest diff in the same card the ticker
/// opens — `lastDiffId` rather than the row itself, so a file edited twice
/// still shows its newest state while the counts stay cumulative.
struct SessionChangesView: View {
    @ObservedObject var state: AppState
    /// Held as an id rather than a FileDiff so the card re-reads itself if the
    /// same file is edited again while it is open.
    @State private var openDiffId: Int?

    private var session: ClaudeSession? { state.focusedClaudeSession ?? state.overviewSession }
    private var scopeKey: String? { session?.sessionId }
    private var changes: [FileChange] { scopeKey.map { state.fileChanges(for: $0) } ?? [] }
    private var totalAdded: Int { changes.reduce(0) { $0 + $1.added } }
    private var totalRemoved: Int { changes.reduce(0) { $0 + $1.removed } }

    var body: some View {
        if let openDiffId, let scopeKey, let diff = state.diff(id: openDiffId, in: scopeKey) {
            DiffCardView(diff: diff) { self.openDiffId = nil }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if changes.isEmpty {
                // Normal for a session the process scan found: it has an id and
                // a name long before Claude Code edits anything.
                Text(String(localized: "No file changes yet"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(changes) { change in
                            row(change)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 108)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { state.view = .overview }
        // ⌘E is the island-wide "open the diff" key, and this is now where most
        // diffs get opened from, so it has to toggle here too. OverviewView
        // hears the same notification but is invisible; its activeDiffId is
        // cleared by onChange(of: state.view) anyway.
        .onReceive(NotificationCenter.default.publisher(for: .islandToggleDiff)) { _ in
            withAnimation(.easeIn(duration: 0.16)) {
                if openDiffId != nil { openDiffId = nil }
                else { openDiffId = changes.first?.lastDiffId }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                state.view = .overview
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .medium))
                    Text(session?.displayName ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(Color(hex: "#F5F6F8"))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 2)
            if totalAdded > 0 {
                Text("+\(totalAdded)")
                    .font(.system(size: 10, weight: .medium).monospaced())
                    .foregroundColor(Color(hex: "#22C55E"))
            }
            if totalRemoved > 0 {
                Text("−\(totalRemoved)")
                    .font(.system(size: 10, weight: .medium).monospaced())
                    .foregroundColor(Color(hex: "#F4505E"))
            }
            // Start the count over. The numbers are cumulative for the life of
            // the session, so without this they only ever grow — there is
            // otherwise no way to ask "what did it change since I last looked?"
            // while the session keeps running.
            if let scopeKey, !changes.isEmpty {
                Button {
                    state.clearSessionDiffs(for: scopeKey)
                    openDiffId = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(hex: "#5F646D"))
                        .frame(width: 14, height: 14)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Reset the counts and clear this list"))
            }
            // Straight to the chat for this session, so the changes view is
            // never a dead end.
            Button {
                state.view = .prompt
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(hex: "#5F646D"))
                    .frame(width: 14, height: 14)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func row(_ change: FileChange) -> some View {
        Button {
            openDiffId = change.lastDiffId
        } label: {
            HStack(spacing: 6) {
                // A dot rather than a "NEW" label: new-file-ness is the least
                // important thing on the row and should not cost a translation.
                if change.isNewFile {
                    Circle()
                        .fill(Color(hex: "#22C55E"))
                        .frame(width: 4, height: 4)
                }
                Text(URL(fileURLWithPath: change.path).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if change.editCount > 1 {
                    Text("×\(change.editCount)")
                        .font(.system(size: 9).monospaced())
                        .foregroundColor(Color(hex: "#5F646D"))
                }
                if change.added > 0 {
                    Text("+\(change.added)")
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundColor(Color(hex: "#22C55E"))
                }
                if change.removed > 0 {
                    Text("−\(change.removed)")
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundColor(Color(hex: "#F4505E"))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(Color(hex: "#5F646D"))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DiffLineRowView: View {
    let line: DiffLine

    private var bgColor: Color {
        switch line.kind {
        case .added:   return Color(hex: "#22C55E").opacity(0.12)
        case .removed: return Color(hex: "#F4505E").opacity(0.12)
        case .context: return Color.clear
        }
    }
    private var fgColor: Color {
        switch line.kind {
        case .added:   return Color(hex: "#86EFAC")
        case .removed: return Color(hex: "#FCA5A5")
        case .context: return Color(hex: "#6B7079")
        }
    }
    private var symbol: String {
        switch line.kind {
        case .added:   return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(symbol)
                .font(.system(size: 10.5).monospaced())
                .foregroundColor(line.kind == .added ? Color(hex: "#22C55E") :
                                 line.kind == .removed ? Color(hex: "#F4505E") :
                                 Color(hex: "#454850"))
                .frame(width: 12, alignment: .leading)
            Text(line.text)
                .font(.system(size: 10.5).monospaced())
                .foregroundColor(fgColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(bgColor)
        .frame(maxWidth: .infinity)
    }
}

#if !APPSTORE
/// The mic's right-click menu: Automatic (the user's languages) or one fixed language.
private struct DictationLanguageMenu: View {
    @Bindable var dictation: MacDictation

    var body: some View {
        let automatic = MacDictation.automaticLocales().map(\.identifier)
        Picker(String(localized: "Dictation language"), selection: $dictation.language) {
            Text(String(localized: "Automatic") + " (" + automatic.map(MacDictation.name(of:)).joined(separator: ", ") + ")")
                .tag(MacDictation.automatic)
            ForEach(quickChoices(automatic), id: \.self) { id in
                Text(MacDictation.name(of: id)).tag(id)
            }
        }
        .pickerStyle(.inline)
        Menu(String(localized: "Other languages")) {
            Picker(String(localized: "Dictation language"), selection: $dictation.language) {
                ForEach(MacDictation.allLanguages, id: \.self) { id in
                    Text(MacDictation.name(of: id)).tag(id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// Automatic's languages, plus the fixed one when it is another.
    private func quickChoices(_ automatic: [String]) -> [String] {
        let chosen = dictation.language
        return chosen == MacDictation.automatic || automatic.contains(chosen) ? automatic : automatic + [chosen]
    }
}
#endif

struct PromptView: View {
    @ObservedObject var state: AppState
    @State private var text: String = ""
    @FocusState private var focused: Bool
    @State private var showNotWiredToast = false
    @State private var chipHovered = false
    @State private var changesChipHovered = false

    /// A session the chat can actually reach: one Coucou has seen hook events
    /// from. Everything host-shaped in this view keys off this — without it the
    /// chips would be naming a process that isn't there.
    private var hasSession: Bool {
        state.focusedSessionId != nil || state.focusTask?.sessionId != nil
    }

    /// Whether a typed message has somewhere to go. Sending types into the
    /// Orca terminal hosting the session (`sendToOrcaTerminal`), so a session
    /// running anywhere else — VS Code, Warp, Terminal — has nothing to type
    /// into: the input would only echo the words and then report "not sent".
    /// With no session at all the picker starts one in an Orca worktree, which
    /// is Orca again, so the input stays.
    private var canSendMessage: Bool {
        guard hasSession else { return true }
        if let session = state.focusedClaudeSession ?? state.overviewSession {
            return ClaudeHost.runsInOrca(session)
        }
        guard let task = state.focusTask else { return false }
        return ClaudeHost.hostId(hostApp: task.hostApp, bundleId: task.sessionBundleId) == ClaudeHost.orcaBundleId
    }

    private var historyBinding: [HistoryEntry] {
        state.focusTask?.history ?? []
    }

    /// Which session the chat is bound to. `displayName` resolves to the
    /// session's title, or to the name Claude Code gave it — the same string
    /// the home view shows.
    private var chatSessionName: String? {
        guard let s = state.overviewSession else { return nil }
        let name = s.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private var focusTaskLabel: String {
        // 1. The session the user explicitly tapped into (right-card pill tap, or
        //    a follow-up left-card tap after the first SessionStart has populated
        //    its hostApp/sessionBundleId).
        if let s = state.focusedClaudeSession { return ClaudeHost.label(for: s) }
        // 2. The session driving the left card (matches what the user just saw
        //    on the home view, even on the very first click before any tap has
        //    set focusedSessionId).
        if let s = state.overviewSession { return ClaudeHost.label(for: s) }
        // 3. Last-resort: the global integration_claude task's most-recent host
        //    (may be stale from a previous terminal session).
        guard let task = state.focusTask else { return "Claude Code" }
        if task.id == "integration_claude" {
            // No live session behind this label. ClaudeHost.name(for: nil)
            // answers "VS Code" because it reads a nil *host* as an editor
            // session — true for a real session, a guess for the bare
            // placeholder pill. Name the agent instead of inventing a host.
            return state.hasOverviewContent
                ? (ClaudeHost.name(for: task.hostApp ?? task.sessionBundleId) ?? "Claude Code")
                : "Claude Code"
        }
        return task.name
    }

    /// The chip's dot, from the same session `focusTaskLabel` names: its
    /// `bodyColor`, the Mochi's own colour. Reading `focusTask.color` instead
    /// answered with whichever pill happened to be focused — a different thing
    /// from the session on screen, and so a different colour for the same
    /// session depending on which page you looked at it from.
    private var hostDotColor: String {
        if let s = state.focusedClaudeSession ?? state.overviewSession { return s.bodyColor }
        return state.focusTask?.color ?? "#7B8089"
    }

    private func scrollHistoryToBottom(proxy: ScrollViewProxy) {
        if let last = historyBinding.last(where: { !$0.content.isEmpty }) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    #if !APPSTORE
    @State private var dictation = MacDictation()
    #endif
    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 6) {
                // Project / session name for the session the chat is bound to.
                // displayName is the session's title, or the name Claude Code
                // gave it — the same string the home pill shows. Sits
                // at the top of the chat card, above the (small) Mochi on the left.
                if let name = chatSessionName {
                    HStack(spacing: 5) {
                        Text(name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#A8ADB5"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        // The way to this session's files from the chat — the
                        // same capsule the home card carries, same numbers and
                        // same colours, so the two never look like two things.
                        if let sid = state.focusedClaudeSession?.sessionId,
                           !state.fileChanges(for: sid).isEmpty {
                            let totals = state.changeTotals(for: sid)
                            Button {
                                state.view = .changes
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(Color(hex: "#5F646D"))
                                    if totals.added > 0 {
                                        Text("+\(totals.added)")
                                            .font(.system(size: 10, weight: .medium).monospaced())
                                            .foregroundColor(Color(hex: "#22C55E"))
                                    }
                                    if totals.removed > 0 {
                                        Text("−\(totals.removed)")
                                            .font(.system(size: 10, weight: .medium).monospaced())
                                            .foregroundColor(Color(hex: "#F4505E"))
                                    }
                                }
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .background(Color.white.opacity(changesChipHovered ? 0.13 : 0.07))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .onHover { changesChipHovered = $0 }
                            .help(String(localized: "Files this session changed"))
                            .contextMenu {
                                Button {
                                    state.clearSessionDiffs(for: sid)
                                } label: {
                                    Label(String(localized: "Reset the counts"),
                                          systemImage: "arrow.counterclockwise")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                    .help(name)
                }
                if state.focusedClaudeSession != nil {
                    // A Claude-session pill was tapped: render that session's JSONL
                    // history instead of the focus task's in-memory log.
                    ChatSessionView(state: state)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, 4)  // breathing room before the input box
                } else if !historyBinding.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(historyBinding) { entry in
                                    ChatBubble(message: ChatMessage(role: entry.role, content: entry.content)).id(entry.id)
                                }
                                if state.stateOverride != nil {
                                    HStack { TypingDotsView(); Spacer(minLength: 32) }
                                        .id("typing")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .reportsScrollAtBottomViaGeometry(for: .prompt, state: state)
                        .onChange(of: historyBinding) { _, _ in
                            scrollHistoryToBottom(proxy: proxy)
                        }
                        .onChange(of: state.stateOverride) { _, v in
                            if v != nil {
                                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                            } else {
                                withAnimation { scrollHistoryToBottom(proxy: proxy) }
                            }
                        }
                        .onAppear {
                            scrollHistoryToBottom(proxy: proxy)
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }

                HStack(spacing: 6) {
                    Spacer()
                    // The chip names where the session runs, so it is the jump:
                    // one control, not an arrow plus a label.
                    if hasSession {
                        Button(action: { openChatTerminal() }) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: hostDotColor))
                                .frame(width: 6, height: 6)
                            Text(focusTaskLabel)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(Color(hex: "#7B8089"))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(chipHovered ? 0.12 : 0.06))
                        .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .onHover { chipHovered = $0 }
                        .help(String(localized: "Open terminal"))
                    }
                }
                .padding(.horizontal, 10)

                if canSendMessage {
                    HStack(spacing: 8) {
                        TextField(historyBinding.isEmpty ? String(localized: "Ask me anything…") : String(localized: "Continue…"), text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focused)
                            .onSubmit { sendMessage() }
    
                        if showNotWiredToast {
                            Text("暂未发送 — Orca 里没找到该 session")
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(hex: "#F4B400"))
                                .lineLimit(1)
                        }
    
                        #if !APPSTORE
                        // Dictate instead of typing (on-device speech recognition when available)
                        Button {
                            Task {
                                if dictation.isRecording { text = await dictation.finish() }
                                else { await dictation.start(from: text) }
                            }
                        } label: {
                            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(dictation.isRecording ? Color(hex: "#F4505E") : Color(hex: "#8E939C"))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(dictation.isRecording ? String(localized: "Stop dictation") : String(localized: "Dictate (right-click to choose the language)"))
                        .contextMenu { DictationLanguageMenu(dictation: dictation) }
                        .onChange(of: dictation.transcript) { _, _ in
                            if dictation.isRecording { text = dictation.text }
                        }
                        #endif
    
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(hex: "#0B0C0E"))
                        }
                        .buttonStyle(SendButtonStyle())
                        .disabled(text.isEmpty)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .simultaneousGesture(TapGesture().onEnded { focused = true })
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .onAppear {
            focused = true
            if let id = state.focusId { state.scheduleReloadHistoryFromJSONL(for: id) }
        }
        .onChange(of: state.view) { _, view in
            if view == .prompt { focused = true }
        }
        .onChange(of: state.focusId) { _, newId in
            if state.view == .prompt, let id = newId {
                state.scheduleReloadHistoryFromJSONL(for: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandSendMessage)) { _ in
            guard state.view == .prompt else { return }
            sendMessage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandNewConversation)) { _ in
            guard state.view == .prompt else { return }
            text = ""
            if let id = state.focusId, let idx = state.tasks.firstIndex(where: { $0.id == id }) {
                state.tasks[idx].history = []
            }
            focused = true
        }
    }

    private func sendMessage() {
        #if !APPSTORE
        // Still dictating: take the final words (and the right language) before sending.
        if dictation.isRecording {
            Task {
                text = await dictation.finish()
                sendMessage()
            }
            return
        }
        #endif
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // Nothing to type into. Echoing the prompt anyway used to leave it
        // sitting in the transcript looking delivered while no agent existed,
        // which is worse than saying so. Keep the words and say it wasn't
        // sent — starting a session from here is gone with the picker, so
        // there is nowhere further to point the user from this view.
        guard state.focusedSessionId != nil || state.focusTask?.sessionId != nil else {
            showNotWiredToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { showNotWiredToast = false }
            return
        }
        text = ""

        // Append the prompt locally so the user sees it immediately, then
        // hand it to Orca to type into the running agent. When Orca can't
        // reach the session we keep the local echo but flag it as not sent.
        if let task = state.focusTask,
           let idx = state.tasks.firstIndex(where: { $0.id == task.id }) {
            state.tasks[idx].history.append(HistoryEntry(role: .user, content: query))
            // Same trick HookServer.appendHistory uses: reassign the slot so
            // @Published on `tasks` fires and ChatSessionView's onChange
            // picks the new in-memory entry up before JSONL catches up.
            state.tasks[idx] = state.tasks[idx]
            // Notify the open ChatSessionView (if any) so it can prepend this
            // exact prompt to its render immediately, scoped to the session
            // the user is currently looking at — not whichever session some
            // other chat might be reading `focusTask.history` for.
            NotificationCenter.default.post(
                name: .userSentChatMessage,
                object: nil,
                userInfo: [
                    "sessionId": state.focusedSessionId as Any,
                    "content": query,
                ]
            )
            appendAppLog("nb.log", "send: pill=\(task.id) session=\(state.focusedSessionId ?? "<nil>") text=\(query.prefix(40))")
            focused = true
            Task { @MainActor in
                let sent = await state.sendToOrcaTerminal(query)
                appendAppLog("nb.log", "send: orca sent=\(sent)")
                if !sent {
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
                    showNotWiredToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { showNotWiredToast = false }
                }
            }
        }
    }

    #if !APPSTORE
    /// Pop back to the home view first (snappy visual feedback), then
    /// jump to the terminal hosting the focused session in the
    /// background. Orca-prefer, matching `performJumpToTerminal`
    /// (⌃⌥T) and the FinishedView's "Open terminal" button.
    private func openChatTerminal() {
        let task = state.focusTask
        Task { @MainActor in
            switchToHome()
            // Orca hosts this session → jump to its exact tab.
            if await state.jumpToOrcaTerminal() { return }
            // Otherwise raise the app the session runs in (its terminal,
            // or VS Code via ClaudeHost), then any known terminal.
            if !(task?.id == "integration_claude" && ClaudeHost.activate(task?.hostApp)),
               !TerminalTarget.activate(sessionBundleId: task?.sessionBundleId) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            }
        }
    }

    /// Same animation as the chat→home overscroll gesture, so the two
    /// exits out of the chat feel identical.
    private func switchToHome() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            state.view = .overview
        }
    }
    #endif
}


// MARK: - Model / provider picker

/// Wrapping horizontal flow layout — used by QuestionView.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let r = rows(maxW: proposal.replacingUnspecifiedDimensions().width, subviews: subviews)
        return r.size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let r = rows(maxW: bounds.width, subviews: subviews)
        for (idx, pt) in r.placements.enumerated() {
            subviews[idx].place(at: CGPoint(x: bounds.minX + pt.x, y: bounds.minY + pt.y), proposal: .unspecified)
        }
    }
    private func rows(maxW: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [(x: CGFloat, y: CGFloat)]) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        var pts: [(x: CGFloat, y: CGFloat)] = []
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += lineH + spacing; lineH = 0 }
            pts.append((x: x, y: y))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: max(maxX, 0), height: y + lineH), pts)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        if !message.content.isEmpty {
            HStack(alignment: .top) {
                if message.role == .user {
                    Spacer(minLength: 32)
                    Text(message.content)
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "#F1F2F4"))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ChatMarkdownView(markdown: message.content)
                    Spacer(minLength: 8)
                }
            }
        }
    }
}

struct TypingDotsView: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(hex: "#6B7079"))
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase ? 1.2 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.14),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 2).padding(.vertical, 4)
        .onAppear { phase = true }
    }
}

// MARK: - Searching

struct SearchingView: View {
    @ObservedObject var state: AppState

    private var label: String {
        String(localized: "Claude is searching…")
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 8) {
                ShimmeringText(label)
                    .font(.system(size: 13.5))
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
        }
    }
}

// MARK: - Result

struct ResultView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .green)

            if let result = state.searchResult {
                VStack(alignment: .leading, spacing: 7) {
                    Text(result.title)
                        .font(.system(size: 15, weight: .semibold))

                    VStack(spacing: 4) {
                        ForEach(result.items.prefix(3), id: \.label) { item in
                            HStack {
                                Text(item.label).font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text(item.detail).font(.system(size: 12.5)).foregroundColor(Color(hex: "#9398A1"))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    if let note = result.note {
                        Text(note).font(.system(size: 11)).foregroundColor(Color(hex: "#6E737C"))
                    }

                    HStack(spacing: 8) {
                        // The URL comes from the model, which may have read attacker-controlled
                        // files or pages: only plain web links may leave the app.
                        let openURL = safeWebURL(result.items.first?.url)
                        PrimaryButton("Open") {
                            if let openURL { NSWorkspace.shared.open(openURL) }
                        }
                        .disabled(openURL == nil)
                        .help(openURL?.absoluteString ?? "")
                        SecondaryButton("Copy") {
                            let text = result.items.map { "\($0.label): \($0.detail)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        SecondaryButton("Close") { state.view = state.tasks.isEmpty ? .empty : .overview }
                    }
                }
                .padding(.leading, 84)
                .padding(.trailing, 16)
            }
        }
    }
}

// MARK: - Note (short message, auto-closes)

struct NoteView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.noteMessage ?? "")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.leading, 98)
        }
    }
}

// MARK: - Integration card (overview left card when an integration pill is focused)

private func ciWorstState(_ prs: [GitHubPR]) -> CIState {
    if prs.contains(where: { $0.ci == .failure }) { return .failure }
    if prs.contains(where: { $0.ci == .pending }) { return .pending }
    if prs.contains(where: { $0.ci == .success }) { return .success }
    return .unknown
}

private func ciColor(_ state: CIState) -> String {
    switch state {
    case .failure: return "#F4505E"
    case .pending: return "#F5A524"
    case .success: return "#22C55E"
    case .unknown: return "#6B7079"
    }
}

private func mainCIWorst(_ repos: [GitHubRepoCI]) -> CIState {
    if repos.contains(where: { $0.ci == .failure }) { return .failure }
    if repos.contains(where: { $0.ci == .pending }) { return .pending }
    if repos.contains(where: { $0.ci == .success }) { return .success }
    return .unknown
}

private struct GitHubStatRow: View {
    let icon: String
    let iconColor: String
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: iconColor))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - GitHub Detail View

private func contributionColor(_ level: Int) -> Color {
    switch level {
    case 1: return Color(hex: "#0E4429")
    case 2: return Color(hex: "#006D32")
    case 3: return Color(hex: "#26A641")
    case 4: return Color(hex: "#39D353")
    default: return Color.white.opacity(0.06)
    }
}

private func ghCIDot(_ ci: CIState) -> Color {
    switch ci {
    case .failure: return Color(hex: "#F4505E")
    case .pending: return Color(hex: "#F5A524")
    case .success: return Color(hex: "#22C55E")
    case .unknown: return Color.clear
    }
}

private struct StatRow: View {
    let icon: String
    let color: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: color))
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stripe Card View

/// How tall the history row laid out, so the current row can sit a fixed gap
/// below it. Reserving a fixed two-line slot instead left a full empty line
/// wherever the shorter of the two rows ended — above a one-line history,
/// under a one-line current step — and the two looked worse together than the
/// truncation that reserving it was meant to avoid.
private struct TickerHistoryHeightKey: PreferenceKey {
    // 22 = one ticker line; a literal because the protocol's defaultValue is
    // nonisolated and TickerView's own statics are main-actor bound.
    nonisolated(unsafe) static var defaultValue: CGFloat = 22
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TickerView: View {
    let task: AgentTask?
    var onDiffTap: ((Int) -> Void)? = nil

    @State private var rowA: String = "…"   // completed (above, left-shifted)
    @State private var rowB: String = "…"   // current (below) → animates diagonally up-left
    @State private var rowC: String = ""    // incoming current — slides in from below

    @State private var rowAOffset: CGFloat = 0
    @State private var rowAOpacity: Double = 1
    @State private var rowBOffset: CGFloat = 0
    @State private var rowBPhase:  Double  = 0   // 0=current, 1=completed (drives X+scale)
    @State private var rowCOffset: CGFloat = Self.height
    @State private var rowCOpacity: Double = 0
    /// Measured, not assumed — see TickerHistoryHeightKey.
    @State private var historyHeight: CGFloat = Self.lineHeight

    @State private var displayIndex: Int = -1
    @State private var isTransitioning = false

    private let completedScale: CGFloat = 11.5 / 13   // 0.885 — matches completed font size

    /// One text line of the ticker.
    static let lineHeight: CGFloat = 22
    /// The history row may use two, the current row below it three. Both are
    /// caps on the text, not slots it has to fill — a short step just takes
    /// fewer lines and the rows close up. The current row's cap is three rather
    /// than four so the card can carry 6pt of air above and below it plus the
    /// bottom ↗ / host chip row without growing: the ticker's height is fixed
    /// from these two numbers, and the card is the tallest state by far, its top
    /// edge crowding the icons.
    static let historyLines = 2
    static let currentLines = 3
    /// Reading between the two rows. Same rhythm as the title above them.
    private static let rowGap: CGFloat = 8
    /// How far the soft edge at each end of the mask reaches, in points.
    /// Only the row passing through an edge mid-transition should be affected.
    private static let edgeFade: CGFloat = 4
    /// Enough for the tallest the ticker can get, and what the incoming row
    /// slides up from.
    static var height: CGFloat { lineHeight * CGFloat(historyLines + currentLines) }

    var steps: [String] {
        let raw = task?.steps ?? []
        return raw.isEmpty ? ["…"] : raw
    }

    var body: some View {
        let isActive = task?.state == .thinking || task?.state == .working
        let rowADiffTap: (() -> Void)? = rowA.parseDiffStep().map { dp in { onDiffTap?(dp.diffId) } }
        let rowBDiffTap: (() -> Void)? = rowB.parseDiffStep().map { dp in { onDiffTap?(dp.diffId) } }

        ZStack(alignment: .topLeading) {
            Color.clear

            // Rows A and B stack, so the current row always sits one gap under
            // the history row no matter how many lines that one took. Offsets
            // still work for the animation: they move a row without moving
            // the other one.
            VStack(alignment: .leading, spacing: Self.rowGap) {
                // Row A: completed row — always rendered at phase=1 + completedScale
                TickerRowView(text: rowA, phase: 1.0, isActive: isActive,
                              lines: Self.historyLines, onDiffTap: rowADiffTap)
                    .scaleEffect(completedScale, anchor: .leading)
                    .offset(x: -10, y: rowAOffset)
                    .opacity(rowAOpacity)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: TickerHistoryHeightKey.self,
                                                   value: geo.size.height)
                        }
                    }

                // Row B: current step → animates diagonally up-left, phase 0→1, scale 1→completedScale
                TickerRowView(text: rowB, phase: rowBPhase, isActive: isActive,
                              lines: Self.currentLines, onDiffTap: rowBDiffTap)
                    .scaleEffect(1 - rowBPhase * (1 - completedScale), anchor: .leading)
                    .offset(x: -rowBPhase * 10, y: rowBOffset)
            }

            // Row C: incoming new step — slides in from below at phase=0
            TickerRowView(text: rowC, phase: 0.0, isActive: isActive)
                .offset(y: rowCOffset)
                .opacity(rowCOpacity)
        }
        .frame(height: Self.height)
        .clipped()
        .mask(LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                // A few points at each edge, NOT a share of the box. The rows
                // hang from the top of a 154pt frame, so a proportional fade
                // ran down the history row and left it looking washed out.
                .init(color: .black, location: Self.edgeFade / Self.height),
                .init(color: .black, location: 1 - Self.edgeFade / Self.height),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        ))
        .onPreferenceChange(TickerHistoryHeightKey.self) { historyHeight = $0 }
        .onAppear { resetRows() }
        .onChange(of: task?.sessionId) { _, _ in
            // The card is showing a different session — picking another one in
            // the list, or the overview falling back. The rows on screen belong
            // to the previous conversation, and the steps-count watcher below
            // won't rescue them: it only fires when the count moves, and two
            // sessions can sit on the same step (both on their first, both with
            // nothing recorded yet).
            resetRows()
        }
        .onChange(of: task?.steps.count) { _, _ in
            guard let task, !task.steps.isEmpty, !isTransitioning else { return }
            let newIdx = task.stepIndex
            if displayIndex < 0 {
                displayIndex = newIdx
                rowA = newIdx > 0 ? steps[max(0, newIdx - 1)] : "…"
                rowB = steps[min(newIdx, steps.count - 1)]
                return
            }
            guard newIdx != displayIndex else { return }
            tickerAnimate(to: newIdx)
        }
    }

    /// Put the rows on the task's current step with no transition state left
    /// over — used on first appearance and whenever the card starts showing a
    /// different session, where animating from the old one's last step would
    /// be a lie about what the new session has done.
    private func resetRows() {
        let idx = task?.stepIndex ?? -1
        displayIndex = idx
        rowAOffset = 0
        rowAOpacity = 1
        rowBOffset = 0
        rowBPhase = 0
        rowC = ""
        rowCOffset = Self.height
        rowCOpacity = 0
        isTransitioning = false
        if idx >= 0, !steps.isEmpty {
            rowA = idx > 0 ? steps[max(0, idx - 1)] : "…"
            rowB = steps[min(idx, steps.count - 1)]
        } else {
            rowA = "…"
            rowB = "…"
        }
    }

    private func tickerAnimate(to newIdx: Int) {
        isTransitioning = true
        rowC = steps[min(newIdx, steps.count - 1)]
        rowCOffset = Self.height
        rowCOpacity = 0

        // How far up "becomes the completed row" is: the history row's own
        // height plus the gap under it, which is exactly where row B already
        // sits and exactly where row C has to land.
        let travel = historyHeight + Self.rowGap

        // Old completed (rowA): fades + slides further up
        withAnimation(.easeOut(duration: 0.28)) {
            rowAOffset  = -travel
            rowAOpacity = 0
        }

        // Current (rowB): moves diagonally up-left + shrinks to completed size
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowBOffset = -travel
            rowBPhase  = 1
        }

        // New current (rowC): slides in from below
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowCOffset  = travel
            rowCOpacity = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            self.displayIndex    = newIdx
            self.rowA            = self.rowB
            self.rowAOffset      = 0
            self.rowAOpacity     = 1
            self.rowB            = self.rowC
            self.rowBOffset      = 0
            self.rowBPhase       = 0
            self.rowCOffset      = Self.height
            self.rowCOpacity     = 0
            self.isTransitioning = false
        }
    }
}

struct TickerRowView: View {
    let text: String
    let phase: Double   // 0 = current (shimmer, large), 1 = completed (dim, scaled down by caller)
    var isActive: Bool = true
    /// How many lines the text may wrap to. It is a cap, not a slot: the row is
    /// as tall as the text actually needs, so the current row can sit directly
    /// under the history row whatever height that one came out at.
    var lines: Int = 1
    var onDiffTap: (() -> Void)? = nil

    var body: some View {
        let chevronOpacity:   Double = isActive ? max(0, 1 - phase * 2)       : 0
        let checkmarkOpacity: Double = isActive ? max(0, phase * 2 - 1)       : 1
        let shimmerOpacity:   Double = isActive ? max(0, 1 - phase * 1.6)     : 0
        let staticOpacity:    Double = isActive ? min(1, max(0, phase * 2 - 0.4)) : 1
        let staticColor = (!isActive && phase < 0.5) ? Color(hex: "#C9CDD4") : Color(hex: "#6B7079")

        if let dp = text.parseDiffStep() {
            HStack(alignment: .top, spacing: 6) {
                ZStack {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .opacity(chevronOpacity)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(Color(hex: "#454850"))
                        .opacity(checkmarkOpacity)
                }
                .frame(width: 12, alignment: .center)
                // Filename + counts
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        TickerShimmerText(text: dp.filename, lines: lines)
                            .opacity(shimmerOpacity)
                        Text(dp.filename)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(staticColor)
                            .lineLimit(lines).truncationMode(.tail)
                            .opacity(staticOpacity)
                    }
                    if dp.added > 0 {
                        Text(" +\(dp.added)")
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundColor(Color(hex: "#22C55E"))
                            .fixedSize()
                    }
                    if dp.removed > 0 {
                        Text(" −\(dp.removed)")
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundColor(Color(hex: "#F4505E"))
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onDiffTap?() }
        } else {
            HStack(alignment: .top, spacing: 6) {
                // Icon: chevron fades out first half, checkmark fades in second half
                ZStack {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .opacity(chevronOpacity)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(Color(hex: "#454850"))
                        .opacity(checkmarkOpacity)
                }
                .frame(width: 12, alignment: .center)

                // Text: shimmer fades out, dim completed text fades in (overlapping cross-fade)
                ZStack(alignment: .leading) {
                    TickerShimmerText(text: text, lines: lines)
                        .opacity(shimmerOpacity)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(staticColor)
                        .lineLimit(lines).truncationMode(.tail)
                        .opacity(staticOpacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TickerShimmerText: View {
    let text: String
    var lines: Int = 1

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2)
            // phase sweeps -0.1 → 1.1 so white peak enters from left and exits right
            let phase = p * 1.2 - 0.1
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(lines)
                .truncationMode(.tail)
                .foregroundStyle(LinearGradient(stops: [
                    .init(color: Color(hex: "#7c818a"), location: max(0, phase - 0.3)),
                    .init(color: Color(hex: "#F2F3F5"), location: max(0, min(1, phase))),
                    .init(color: Color(hex: "#7c818a"), location: min(1, phase + 0.3)),
                ], startPoint: .leading, endPoint: .trailing))
        }
    }
}

// MARK: - Active Claude Code sessions (overview right card)

// One pill per running Claude Code process. Mirrors `AgentPill`'s visual language
// (dark capsule, mini Mochi, hover scale) but adds a one-line subtitle showing the
// short cwd and the app the session is locked into.
struct ClaudeSessionPill: View {
    let session: ClaudeSession
    @ObservedObject var state: AppState
    let onTap: () -> Void
    /// Double-click: straight to this session's chat, without the detour
    /// through the left card that a single click does.
    let onDoubleTap: () -> Void
    @State private var isHovered = false
    /// When the click before this one landed, 0 when there isn't one. The
    /// double-click is counted here rather than with `onTapGesture(count: 2)`:
    /// SwiftUI holds a single tap back until the double-click window closes, so
    /// asking for both on the same view made *every* click land ~0.3s late.
    @State private var lastTapAt: CFTimeInterval = 0

    /// Window two clicks must fall inside to read as a double-click. Matches
    /// the platform's own double-click interval.
    private static let doubleClickWindow: CFTimeInterval = 0.3

    /// A single click moves the character to the left card; a second one
    /// inside the window opens the chat instead. The pair is consumed, so a
    /// third click starts a fresh single.
    private func handleTap() {
        let now = CACurrentMediaTime()
        if lastTapAt > 0, now - lastTapAt < Self.doubleClickWindow {
            lastTapAt = 0
            onDoubleTap()
        } else {
            lastTapAt = now
            onTap()
        }
    }

    private static let claudeColor = PillCatalog.definition(for: "integration_claude")?.color ?? "#F5F6F8"

    /// Synthesise an `AgentTask` so we can reuse `MiniBotCanvasView` without forking it.
    /// Each session keeps its own random body color + outfit, picked on first
    /// appearance (see `Array<ClaudeSession>.upsert`).
    private var botTask: AgentTask {
        AgentTask(
            id: "session:\(session.sessionId)",
            name: session.projectName,
            color: session.bodyColor,
            state: session.state,
            steps: [],
            source: .claudeCode,
            outfit: session.outfit
        )
    }

    /// Under the session name: where it runs. For a session the process scan found
    /// there is no host to name — `ClaudeHost.name(for: nil)` would answer "VS
    /// Code", a guess that only holds for editor sessions — so show the folder
    /// it is working in instead.
    private var subtitle: String {
        if session.provisional { return String(localized: "Started · no events yet") }
        // Only where the session runs. The title above is the session's name
        // now, so there is nothing left to add: where it runs is the one
        // thing the name doesn't say.
        return ClaudeHost.label(for: session)
    }

    var body: some View {
        // A plain ZStack + tap gesture, not a Button: the ↗ jump button lives
        // inside the same view that owns the hover, so moving onto it can't
        // bounce the hover state (a Button nested in a Button did exactly that
        // and spun the render loop).
        ZStack {
            // The state dot sits at Mochi's lower-left: his head now carries
            // the state badge (MiniBotCanvasView draws it), so the top-right
            // corner holds the ↗ instead.
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    Capsule()
                        .fill(isHovered
                              ? Color(hex: Self.claudeColor).opacity(0.18)
                              : Color(hex: "#0E0F11"))
                    Capsule()
                        .stroke(Color(hex: Self.claudeColor).opacity(isHovered ? 0.55 : 0.14), lineWidth: 1)

                    HStack(spacing: 0) {
                        MiniBotCanvasView(task: botTask)
                            .frame(width: 22 / 0.6, height: 22 / 0.6)
                            .frame(width: 22, height: 22, alignment: .center)
                            .padding(.leading, 8)
                        Spacer(minLength: 0)
                    }
                    .allowsHitTesting(false)

                    VStack(spacing: 1) {
                        Text(session.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isHovered
                                             ? Color(hex: Self.claudeColor).lighter(by: 0.3)
                                             : Color(hex: "#6B7079"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#5F646D"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 34)
                    .padding(.trailing, 24)
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .shadow(color: Color(hex: Self.claudeColor).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)
                // ↗ always visible, exactly like the overview card's: jumping
                // to a session's terminal is one click from every pill. It used
                // to appear on hover, but that flickered in and out while a
                // session was running, so its presence never depends on hover.
                .overlay(alignment: .topTrailing) {
                    // A Button's gesture wins over the ancestor onTapGesture,
                    // which is why the ↗ has always been clickable without also
                    // opening the card. The card itself opens the chat, so no
                    // second control is needed here.
                    Button {
                        AgentLauncher.open(state.overviewTask(for: session), state: state)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(Color(hex: "#5F646D"))
                            .frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .padding(.trailing, 4)
                }
                // No status dot here. The Mochi already carries one, drawn by
                // BotEngine's badge: three pulsing dots while it's working, a
                // single dot when finished. A second static dot told the same
                // story with less information — it couldn't distinguish
                // "moving" from "just finished" — and sat ~4px from the badge,
                // so the two read as one confusing pair. Left to the character.
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .onHover { newHover in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
        // Right-click opens the wardrobe for *this* pill's session. The
        // wardrobe reads `state.overviewSession`, which follows
        // `focusedSessionId`, so focus this session first — without it the
        // wardrobe dressed whichever session the left card happened to show.
        .contextMenu {
            Button {
                state.focusedSessionId = session.sessionId
                state.view = .wardrobe
            } label: {
                Label(String(localized: "Change outfit…"), systemImage: "tshirt")
            }
            // Copying the name is how a session gets handed to someone else:
            // the pill's own label is truncated, and Claude Code addresses a
            // session by the name `copyableName` carries. Sits above the
            // divider because copying is not destructive.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.copyableName, forType: .string)
            } label: {
                Label(String(localized: "Copy Name"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                state.hideClaudeSession(session.sessionId)
            } label: {
                Label(String(localized: "Stop monitoring"), systemImage: "eye.slash")
            }
        }
    }
}

/// Right-side card content: live Claude Code sessions, with a one-pill fallback to the
/// existing service pills when no session is active. Lazy so off-screen rows do no work
/// (and the view costs 0% CPU while the island is hidden).
struct ClaudeSessionsListView: View {
    @ObservedObject var state: AppState
    @State private var swapping = false
    @State private var showHidden = false

    // "+": start a Claude Code session in an Orca project, from the list
    // itself rather than by going through the chat first. Only where that is
    // actually possible — with no Orca there is no project to start in.
    private var canStartInProject: Bool { OrcaCLIBridge.isInstalled }

    /// Fallback threshold for sessions the relay gave us no pid for (an agent
    /// still on an older relay, or a parent chain it couldn't resolve). Only
    /// these age out — a session that reported a pid is judged by whether its
    /// process is still alive, never by how long ago the last event arrived:
    /// a session idling at the prompt fires no events at all, and used to
    /// vanish from here after 30 minutes while its process was perfectly fine.
    private static let idleCutoff: TimeInterval = 30 * 60

    private var live: [ClaudeSession] {
        let cutoff = Date().addingTimeInterval(-Self.idleCutoff)
        return state.visibleClaudeSessions.filter { s in
            if s.pid != nil { return state.isClaudeSessionAlive(s) }
            return s.lastEventAt >= cutoff
        }
    }

    /// Sessions the user has hidden via "Stop monitoring" but the process is
    /// still firing hooks (i.e. hiddenClaudeSessionIds is non-empty AND the
    /// 30-min idle cutoff hasn't dropped the live list to empty). The list of
    /// ids is enough — we don't need a full ClaudeSession because hidden
    /// entries never made it into `claudeSessions` to begin with.
    private var hiddenCount: Int { state.hiddenClaudeSessionIds.count }

    /// One project's sessions, for the grouped list.
    private struct ProjectGroup: Identifiable {
        let key: String                  // the folder — the precise grouping key
        let name: String                 // what we display, and colour by
        let sessions: [ClaudeSession]
        var id: String { key }
    }

    /// `live` grouped by project, keeping its most-recent-first order: a group
    /// sits where its most recent session sat, and sessions inside it stay in
    /// recency order. So the project you're working in floats to the top with
    /// no extra sorting.
    ///
    /// Keyed on `cwd` rather than `projectName`: two folders can share a
    /// basename, and merging unrelated work because they're both called
    /// "api" would be worse than showing two groups with the same label.
    private var groups: [ProjectGroup] {
        var order: [String] = []
        var byKey: [String: [ClaudeSession]] = [:]
        for s in live {
            let key = s.cwd.isEmpty ? s.projectName : s.cwd
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(s)
        }
        return order.map { key in
            let sessions = byKey[key] ?? []
            return ProjectGroup(key: key,
                                name: sessions.first?.projectName ?? key,
                                sessions: sessions)
        }
    }

    private static let columns = [GridItem(.flexible(), spacing: 4),
                                  GridItem(.flexible(), spacing: 4)]

    /// The project's name over its sessions.
    ///
    /// No colour dot: it used to take the project's colour from
    /// IslandConst.colorForProject, which only knows a handful of projects and
    /// falls back to a hash of the name for the rest — so for most projects it
    /// was a random dot that meant nothing. Worse, the fallback green (#22C55E)
    /// is also the "finished" state colour, so a green dot meant two different
    /// things depending on where it sat. The heading text already says which
    /// project this is.
    private func projectHeader(_ group: ProjectGroup) -> some View {
        HStack(spacing: 5) {
            Text(group.name)
                // Deliberately smaller than the pill titles (10pt): the header
                // organises the list, it isn't a thing to read first.
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(group.sessions.count)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(Color(hex: "#5F646D"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 3)
    }

    var body: some View {
        // ZStack so the hidden chip stays visible at the bottom even when
        // the ScrollView is full of session pills (VStack would push it
        // out of the card's clipped area).
        ZStack(alignment: .bottom) {
            // The project list takes the card over rather than layering on
            // top of it: the pills underneath would show through and there
            // would be nowhere to tap "anywhere else" to close it.
            if state.showProjectPicker {
                projectPanel
            } else if live.isEmpty {
                // No active Claude session — leave the right card empty.
                // The previous fallback to AgentPillsView (Cursor / Codex /
                // Gemini / …) is gone: this view only renders Claude work.
                Color.clear
            } else {
                // Grouped by project, two columns per group. Scrollable because the
                // island's height is fixed at 160pt: grouping decides what fits
                // above the fold, not what exists. No border / indicator — the
                // right card already sits inside its own CardBackground. Bottom
                // padding leaves room for the hidden chip overlay.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                projectHeader(group)
                                LazyVGrid(columns: Self.columns,
                                          alignment: .leading,
                                          spacing: 4) {
                                    ForEach(group.sessions) { s in
                                        ClaudeSessionPill(session: s, state: state,
                                                          onTap: { select(s) },
                                                          onDoubleTap: { openChat(s) })
                                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    // Room for the pinned + button, so a long project name
                    // truncates against it rather than running underneath.
                    .padding(.trailing, canStartInProject ? 18 : 0)
                    // Reserve room so the last pill isn't hidden under the chip.
                    .padding(.bottom, hiddenCount > 0 ? 32 : 0)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.78), value: live.count)
            }
            if hiddenCount > 0 {
                hiddenSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel swaps the list out rather than layering over it, so it
        // needs the same animation the pills get.
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: state.showProjectPicker)
        // Pinned to the card's top-right rather than living in the scroll: the
        // list scrolls under it, and it has to be reachable from every
        // project — including an empty card, where starting a session is the
        // only thing there is to do. Gone while the panel is open: the panel
        // brings its own close button, and two of them a few pixels apart
        // read as two unrelated controls.
        .overlay(alignment: .topTrailing) {
            if canStartInProject && !state.showProjectPicker { addButton }
        }
        .task {
            // A killed process announces nothing, so there is no event to
            // re-render this list — the stale pill would sit there until the
            // user happened to touch something. Poll while the card is on
            // screen; `.task` is cancelled when it goes away, so a hidden
            // island stays at 0% CPU.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                state.pruneDeadClaudeSessions()
                // A card built by a hook event carries no name, and an empty
                // list can still mean a session started before us — both are
                // fixed by the same re-check of the process table, which is
                // rate-limited inside. Once every session is named there is
                // nothing left for it to find, so it stops spawning shells.
                let sessions = state.visibleClaudeSessions
                if sessions.isEmpty || sessions.contains(where: { $0.sessionName.isEmpty }) {
                    state.scanForRunningClaudeSessions()
                }
            }
        }
    }

    /// "Hidden: N" chip + a popover with one row per hidden session, each
    /// with a Resume button. Lets the user undo "Stop monitoring" without
    /// restarting the app or hand-editing UserDefaults.
    @ViewBuilder
    private var hiddenSection: some View {
        Button {
            showHidden.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                Text(String(format: String(localized: "Hidden · %d"), hiddenCount))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(Color(hex: "#7B8089"))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .popover(isPresented: $showHidden, arrowEdge: .bottom) {
            hiddenPopover
        }
    }

    /// Start a new Claude Code session in an Orca project. The empty state's
    /// "Ask Claude" button opens the same list; this is the way in from the
    /// list itself, without going home first.
    private var addButton: some View {
        Button {
            state.showProjectPicker.toggle()
            if state.showProjectPicker { Task { await state.loadOrcaWorktrees() } }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(hex: "#5F646D"))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.07))
                .clipShape(Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.trailing, 8)
        .help(String(localized: "Start a Claude Code session in a project"))
    }

    /// The project list, opening over the session list. Not a popover: AppKit
    /// decides where a popover goes, and next to the card's top-right corner
    /// it kept putting this to the side — over the cards behind it, at an
    /// arrow angle that pointed at nothing. The island keeps its height, so
    /// the list scrolls past the card's bottom instead.
    @ViewBuilder
    private var projectPanel: some View {
        if state.showProjectPicker {
            OrcaProjectPickerList(state: state,
                                  isPresented: $state.showProjectPicker,
                                  onStarted: { wt, began in
                // Open the session we just started, the way double-clicking a
                // pill in this same list would — starting a session you then
                // have to go find is the half-finished version of that.
                Task { @MainActor in
                    guard await state.focusClaudeSessionStarted(inCwd: wt.path,
                                                                since: began) != nil else { return }
                    state.view = .prompt
                }
            })
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .transition(.opacity)
        }
    }

    /// What to call a hidden session. The raw uuid told the user nothing they
    /// could act on — they can't tell which of a dozen sessions it is. Prefer
    /// the snapshot taken when it was hidden, then whatever name we last knew,
    /// and only fall back to the id when a restart has left us nothing else.
    private func hiddenTitle(for sessionId: String) -> String {
        if let saved = state.hiddenClaudeSessions[sessionId] {
            return saved.displayName
        }
        return sessionId
    }

    private var hiddenPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Hidden sessions"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text(String(localized: "These sessions are not shown in the list. Resume to re-monitor them."))
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#7B8089"))
                .fixedSize(horizontal: false, vertical: true)
            Divider().background(Color(hex: "#2A2C30"))
            ForEach(Array(state.hiddenClaudeSessionIds).sorted(), id: \.self) { sid in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hiddenTitle(for: sid))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // Only shown when there's no snapshot to name the
                        // session by — after a restart the snapshot is gone
                        // (only ids are persisted) and the id is all we have.
                        if hiddenTitle(for: sid) == sid {
                            Text(sid)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Color(hex: "#7B8089"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(String(localized: "Resume")) {
                        state.unhideClaudeSession(sid)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#5F8AFA"))
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(Color(hex: "#141518"))
    }

    /// A pill tap only *selects* the session: it drives the left card, and the
    /// left card is the way into the chat. Jumping straight to the chat from
    /// here meant browsing the list and landing somewhere else entirely —
    /// picking the next thing to look at lost the list you were picking from.
    private func select(_ s: ClaudeSession) {
        guard !swapping else { return }
        swapping = true
        SoundEngine.shared.play("blip")
        state.focusedSessionId = s.sessionId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { swapping = false }
    }

    /// Double-click: focus the session and open its chat in one go — the same
    /// destination the left card opens, minus the extra click.
    private func openChat(_ s: ClaudeSession) {
        state.focusedSessionId = s.sessionId
        state.view = .prompt
    }
}

/// The Orca project list, shared by the chat's "Pick a project" chip and the
/// overview's + button: picking a row starts a Claude Code session in that
/// worktree. Starting lives here rather than in the callers because both do
/// exactly the same thing; they differ only in what a failure means, which
/// `onFinish` hands back.
struct OrcaProjectPickerList: View {
    @ObservedObject var state: AppState
    /// Dismissed by this view once the session is up, so the caller doesn't
    /// have to wire the popover to its own start handler.
    @Binding var isPresented: Bool
    /// The start failed. The caller has nothing to put back — both entry
    /// points reach this list before any words were typed — so the failure
    /// stays an inline line under the rows.
    var onFailure: () -> Void = {}
    /// The agent is up. Carries the worktree and the moment the start began:
    /// the session announces itself over the hook a moment later, so a caller
    /// that wants to open it needs both to find it rather than an older
    /// session in the same folder.
    var onStarted: (OrcaWorktree, Date) -> Void = { _, _ in }

    @State private var startingInPath: String? = nil
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(String(localized: "Start Claude Code in an Orca project"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#8E939C"))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close"))
            }
            if state.orcaWorktreesLoading {
                Text(String(localized: "Loading…"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
            } else if let list = state.orcaWorktrees, !list.isEmpty {
                // Fills whatever height the island gave the panel and scrolls
                // past it — the island clips to its own shape, so a list that
                // outgrew the page it opened over would lose its last rows.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(list) { wt in
                            Button {
                                start(in: wt)
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(wt.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(Color(hex: "#F5F6F8"))
                                        Text(wt.path)
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(hex: "#6B7079"))
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                    Spacer(minLength: 6)
                                    if startingInPath == wt.path {
                                        ProgressView().controlSize(.mini)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(startingInPath != nil)
                        }
                        // Orca answered, the create didn't take. Kept inline rather than
                        // as a toast: the picker is still open, and a line under the
                        // rows is where the failure belongs.
                        if failed {
                            Text("暂未启动 — 检查一下这个项目")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#F4B400"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Orca is installed but answered with nothing usable — say so
                // instead of showing a picker that can only fail.
                Text(String(localized: "No Orca projects found. Open one in Orca first."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No background of its own: both call sites put it inside a
        // CardBackground, and a second rounded rect read as a shorter card
        // floating inside the real one — the padding above had already
        // inset it on every side.
    }

    /// Spawn Claude Code in `wt`. No prompt rides along: both callers reach
    /// this list before anything was typed.
    private func start(in wt: OrcaWorktree) {
        startingInPath = wt.path
        failed = false
        let began = Date()
        Task { @MainActor in
            let ok = await state.startClaudeSession(in: wt.path, prompt: nil)
            startingInPath = nil
            if ok {
                isPresented = false
                onStarted(wt, began)
            } else {
                failed = true
                onFailure()
            }
        }
    }
}

// MARK: - Music Pill (GitHub build only)

#if !APPSTORE
#endif

// MARK: - Music Card View (GitHub build only)

#if !APPSTORE
#endif

struct PillBadgeView: View {
    let badge: PillBadge
    let taskColor: String

    private var badgeColor: Color {
        switch badge {
        case .approval: return Color(hex: "#F5A524")
        case .question: return Color(hex: "#22D3EE")
        case .finished: return Color(hex: "#22C55E")
        case .error:    return Color(hex: "#F4505E")
        }
    }

    private var icon: String {
        switch badge {
        case .approval: return "exclamationmark"
        case .question: return "questionmark"
        case .finished: return "checkmark"
        case .error:    return "xmark"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "#0B0C0E"))
                .frame(width: 14, height: 14)
            Circle()
                .fill(badgeColor)
                .frame(width: 12, height: 12)
            Image(systemName: icon)
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(.black)
        }
        .shadow(color: badgeColor.opacity(0.6), radius: 4, x: 0, y: 0)
    }
}

// MARK: - Column agents (right side of non-overview views)

struct ColumnAgentsView: View {
    @ObservedObject var state: AppState

    var others: [AgentTask] {
        state.tasks.filter { $0.id != state.focusId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(others.prefix(4).enumerated()), id: \.1.id) { idx, task in
                MiniBotCanvasView(task: task)
                    .frame(width: 16 / 0.6, height: 16 / 0.6)
                    .frame(width: 16, height: 16)
                    .position(x: 0, y: CGFloat(50 + idx * 24))
                    .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(Double(idx) * 0.035), value: idx)
            }
        }
    }
}

// MARK: - Wardrobe

struct WardrobeView: View {
    @ObservedObject var state: AppState
    @State private var hoveredOutfit: Outfit? = nil
    @State private var hoveredColor: String? = nil
    @State private var nameHovered = false

    /// The outfit currently displayed on the right pill / main Mochi.
    /// Driven by the active `overviewSession` so editing here and right-clicking
    /// a pill on the right card both edit the same value.
    private var currentOutfit: Outfit {
        state.overviewSession?.outfit ?? .none
    }

    /// The body colour currently on the Mochi, same source as `currentOutfit`.
    private var currentBodyColor: String? {
        state.overviewSession?.bodyColor
    }

    /// The name in the field. It starts as the session's name and becomes
    /// the session's name again once it is written — the session's name
    /// lives in its transcript, and the field only writes there once the user
    /// is done typing.
    @State private var nameDraft: String = ""
    /// Whether the name field holds the keyboard, so the name is written
    /// when the user leaves the field rather than on every keystroke.
    @FocusState private var nameFocused: Bool

    /// Reads and writes the active session's name: same source as
    /// `currentOutfit` / `currentBodyColor`, so right-clicking another pill
    /// and coming back here edits that session.
    private var nameBinding: Binding<String> {
        Binding(
            get: { nameDraft },
            set: { nameDraft = $0 }
        )
    }

    /// Put the session's name into the field. Called when the wardrobe opens
    /// and when the session under it changes.
    private func loadName() {
        nameDraft = state.overviewSession?.displayName ?? ""
    }

    /// Rename the session, the way Claude Code's own `/rename` does, so the
    /// two agree on what the session is called.
    ///
    /// An empty field is not a rename: the session keeps the name it has,
    /// and the field goes back to showing it. Nothing happens when the name
    /// hasn't changed either — opening the wardrobe and leaving it again must
    /// not disturb anything.
    private func commitName() {
        guard let s = state.overviewSession else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameDraft = s.displayName
            return
        }
        guard name != s.displayName else { return }
        state.renameSession(s.sessionId, to: name)
    }

    /// The grey line shown while the field is empty: the name the session
    /// goes by when it has no name of its own.
    private var emptyNameHint: String {
        guard let s = state.overviewSession else { return "" }
        if !s.aiTitle.isEmpty { return s.aiTitle }
        if !s.sessionName.isEmpty { return s.sessionName }
        return s.projectName
    }

    private var headerRight: String {        // Hover takes priority: the colour pointed at, then the outfit.
        if let hex = hoveredColor,
           let name = ClaudeSession.palette.first(where: { $0.hex == hex })?.name {
            return name
        }
        if let h = hoveredOutfit {
            if h == .auto {
                let seasonal = Outfit.seasonal(for: Date(), calendar: .current)
                let name = seasonal == .none ? "None" : seasonal.displayName
                return "Auto · follows the seasons (now: \(name))"
            }
            return h.displayName
        }
        // Fall back to the session's current outfit
        let sel = currentOutfit
        if sel == .none {
            let seasonal = Outfit.seasonal(for: Date(), calendar: .current)
            let name = seasonal == .none ? "None" : seasonal.displayName
            return "Auto · \(name)"
        }
        return sel.displayName
    }

    /// The name the home view shows, editable. It reads as plain text until
    /// you point at it, when it gains a background and brightens. The
    /// TextField is always in the hierarchy — swapping a Text for a TextField
    /// on hover made the pointer bounce in and out of hover, the same trap the
    /// pill's jump button fell into.
    private var nameField: some View {
        ZStack(alignment: .leading) {
            // The hint is drawn by hand rather than left to the TextField's own
            // placeholder: that one takes its colour from the system appearance,
            // so on a black island in light mode it comes out black — invisible.
            if nameDraft.isEmpty {
                Text(emptyNameHint)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#7B8089"))
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
            TextField("", text: nameBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: nameHovered ? "#F5F6F8" : "#8E939C"))
                .lineLimit(1)
                .focused($nameFocused)
                .onSubmit { commitName() }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitName() }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(nameHovered ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 8))
        .onHover { nameHovered = $0 }
        .help(emptyNameHint)
    }

    /// The model: the Mochi stands here — `BotPlacement` draws it over this
    /// column.
    ///
    /// The hole the Mochi stands in is reserved, not empty: the Mochi is drawn
    /// by the island, outside this view, so the space it takes has to be kept
    /// here for the two to line up.
    private var modelColumn: some View {
        Color.clear.frame(width: 58, height: 58)
            .frame(width: 110)
    }

    /// The rack: the session's name, the hats on a single row, and the Mochi's
    /// body colour under them.
    private var rackColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // The name takes the place the page title used to have: it is
                // what the wardrobe is dressing, so it heads the rack.
                nameField
                    .frame(width: 190)
                    .overlay(alignment: .top) {
                        // The name didn't make it into the session. It stays in
                        // the field, so the user's words aren't lost — say so,
                        // though. The message floats under the field instead of
                        // taking a row of its own, so nothing moves when it
                        // appears.
                        if let error = state.renameError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#F4B400"))
                                .lineLimit(1)
                                .padding(.top, 24)
                        }
                    }
                Spacer(minLength: 4)
                Text(headerRight)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                ForEach(outfits, id: \.rawValue) { outfit in
                    OutfitPillView(
                        outfit: outfit,
                        isSelected: (outfit == .auto ? .none : outfit) == currentOutfit,
                        isHovered: hoveredOutfit == outfit,
                        onHover: { h in
                            hoveredOutfit = h ? outfit : nil
                            if h {
                                // Preview on main Mochi
                                let preview: Outfit = outfit == .auto
                                    ? Outfit.seasonal(for: Date(), calendar: .current)
                                    : outfit
                                state.wardrobePreviewOutfit = preview
                            } else if hoveredOutfit == nil {
                                state.wardrobePreviewOutfit = nil
                            }
                        },
                        onTap: {
                            // `.auto` → outfit `.none` (falls back to seasonal in BotCanvasView).
                            let target: Outfit = outfit == .auto ? .none : outfit
                            guard target != currentOutfit else { return }
                            if let s = state.overviewSession {
                                state.setSessionOutfit(s.sessionId, target)
                            }
                            SoundEngine.shared.play("pop")
                            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
                        },
                        seasonalOutfit: outfit == .auto ? state.resolvedOutfit : .none
                    )
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 8) {
                ForEach(ClaudeSession.palette) { option in
                    ColorSwatchView(
                        hex: option.hex,
                        isSelected: option.hex == currentBodyColor,
                        isHovered: hoveredColor == option.hex,
                        onHover: { hoveredColor = $0 ? option.hex : nil },
                        onTap: {
                            guard let s = state.overviewSession, option.hex != currentBodyColor else { return }
                            state.setSessionBodyColor(s.sessionId, option.hex)
                            SoundEngine.shared.play("pop")
                            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
                        })
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every hat the wardrobe offers, `auto` first.
    private var outfits: [Outfit] {
        [Outfit.auto] + Outfit.allCases.filter { $0 != .auto }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // One card for the whole page, the way the chat page has one:
            // the Mochi stands on it like it stands on the chat's.
            CardBackground(wash: .indigo)

            // Two columns, each centred as a group: the model on the left,
            // the rack on the right.
            HStack(alignment: .center, spacing: 12) {
                modelColumn
                rackColumn
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadName() }
        .onChange(of: state.overviewSession?.sessionId) { _, _ in loadName() }
        .onChange(of: state.overviewSession?.displayName) { _, _ in
            // The session was renamed somewhere else — in the terminal, or by
            // the write this field just made. Follow it, unless the user is
            // halfway through typing a name of their own.
            if !nameFocused { loadName() }
        }
        .onDisappear {
            state.wardrobePreviewOutfit = nil
            hoveredOutfit = nil
            hoveredColor = nil
            nameHovered = false
        }
        .onExitCommand {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = .overview
            }
        }
    }
}

/// A body colour in the wardrobe's colour row: a plain dot, smaller than the
/// outfit tiles so the row stays short. Selected gets a ring just outside it.
struct ColorSwatchView: View {
    let hex: String
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: 18, height: 18)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                    .padding(-3)
            }
            .scaleEffect(isHovered ? 1.15 : 1)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onHover { onHover($0) }
            .onTapGesture { onTap() }
    }
}

struct OutfitPillView: View {
    let outfit: Outfit
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    var seasonalOutfit: Outfit = .none

    var body: some View {
        Canvas { context, size in
            drawOutfitIcon(context: context, size: size, outfit: outfit, seasonal: seasonalOutfit)
        }
        .frame(width: 30, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered ? Color.white.opacity(0.10) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.white.opacity(0.40) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .onHover { onHover($0) }
        .onTapGesture { onTap() }
    }
}

private func drawOutfitIcon(context: GraphicsContext, size: CGSize, outfit: Outfit, seasonal: Outfit = .none) {
    let W = size.width, H = size.height
    let cx = W / 2, cy = H / 2
    let R: CGFloat = 6.5   // small scale for icon

    switch outfit {
    case .auto:
        let iconR: CGFloat = 10.0
        let rx = iconR * 1.14, ry = iconR * 0.88
        let mH = MochiH(R: iconR, yaw: 0, pitch: 0)
        let bodyPath = mochiOutfitPath(rx, ry)
        let iconCY = cy + iconR * 0.62

        // Draw the seasonal outfit behind body
        if seasonal != .none && seasonal != .auto {
            drawOutfitBehindStatic(context: context, outfit: seasonal, H: mH,
                                   cx: cx, cy: iconCY, tilt: 0, sx: 1, sy: 1,
                                   roll: 0, morph: 0, isMini: false)
        }
        // Body
        var ctx = context
        ctx.translateBy(x: cx, y: iconCY)
        ctx.fill(bodyPath, with: .linearGradient(
            Gradient(colors: [Color(red: 0.929, green: 0.929, blue: 0.937),
                              Color(red: 0.769, green: 0.773, blue: 0.792)]),
            startPoint: CGPoint(x: rx*0.7, y: -ry*0.85),
            endPoint:   CGPoint(x: -rx*0.8, y: ry*0.9)
        ))
        ctx.fill(bodyPath, with: .radialGradient(
            Gradient(stops: [.init(color: .clear, location: 0.6),
                             .init(color: Color.black.opacity(0.2), location: 1)]),
            center: .zero, startRadius: iconR*0.15, endRadius: iconR*1.25
        ))
        // Eyes
        var eyeCtx = ctx; eyeCtx.clip(to: bodyPath)
        let ink = Color(red: 0.102, green: 0.082, blue: 0.071)
        for f in mEyeFrames(mH) {
            guard f.visible else { continue }
            var ec = eyeCtx; ec.translateBy(x: f.x, y: f.y); ec.scaleBy(x: f.fx, y: f.fy)
            let hh = max(f.h, f.w*0.3)
            var pill = Path()
            pill.addRoundedRect(in: CGRect(x: -f.w/2, y: -hh/2, width: f.w, height: hh),
                                cornerSize: CGSize(width: min(f.w/2,hh/2), height: min(f.w/2,hh/2)))
            ec.fill(pill, with: .color(ink))
        }
        // Front outfit
        if seasonal != .none && seasonal != .auto {
            drawOutfitFrontStatic(context: context, outfit: seasonal, H: mH,
                                  cx: cx, cy: iconCY, tilt: 0, sx: 1, sy: 1,
                                  roll: 0, morph: 0, isMini: false)
        }
        // AUTO badge at bottom
        var badgeCtx = context
        let badgeCY = iconCY + ry * 0.72
        badgeCtx.translateBy(x: cx, y: badgeCY)
        let bw: CGFloat = 14, bh: CGFloat = 6.5
        var badge = Path()
        badge.addRoundedRect(in: CGRect(x: -bw/2, y: -bh/2, width: bw, height: bh),
                             cornerSize: CGSize(width: bh/2, height: bh/2))
        badgeCtx.fill(badge, with: .color(Color.black.opacity(0.60)))
        badgeCtx.draw(Text("AUTO").font(.system(size: 4.2, weight: .semibold)).foregroundColor(.white),
                      at: .zero)

    case .none:
        var ctx = context
        ctx.translateBy(x: cx, y: cy)
        // Circle with diagonal slash (⊘)
        var circle = Path()
        circle.addEllipse(in: CGRect(x: -R * 0.82, y: -R * 0.82, width: R * 1.64, height: R * 1.64))
        ctx.stroke(circle, with: .color(Color(hex: "#454850")), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        var slash = Path()
        slash.move(to:    CGPoint(x: -R * 0.56, y:  R * 0.56))
        slash.addLine(to: CGPoint(x:  R * 0.56, y: -R * 0.56))
        ctx.stroke(slash, with: .color(Color(hex: "#454850")), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

    default:
        // Small Mochi wearing the outfit
        let iconR: CGFloat = 10.0
        let rx = iconR * 1.14, ry = iconR * 0.88
        let mH = MochiH(R: iconR, yaw: 0, pitch: 0)
        let bodyPath = mochiOutfitPath(rx, ry)
        let iconCY = cy + iconR * 0.62

        // Draw outfit behind
        drawOutfitBehindStatic(context: context, outfit: outfit, H: mH,
                               cx: cx, cy: iconCY, tilt: 0, sx: 1, sy: 1,
                               roll: 0, morph: 0, isMini: false)

        // Draw body
        var ctx = context
        ctx.translateBy(x: cx, y: iconCY)
        let top = Color(red: 0.929, green: 0.929, blue: 0.937)
        let bot = Color(red: 0.769, green: 0.773, blue: 0.792)
        ctx.fill(bodyPath, with: .linearGradient(
            Gradient(colors: [top, bot]),
            startPoint: CGPoint(x: rx * 0.7, y: -ry * 0.85),
            endPoint:   CGPoint(x: -rx * 0.8, y: ry * 0.9)
        ))
        ctx.fill(bodyPath, with: .radialGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.6),
                .init(color: Color.black.opacity(0.2), location: 1)
            ]),
            center: .zero, startRadius: iconR * 0.15, endRadius: iconR * 1.25
        ))
        ctx.fill(bodyPath, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0.55), location: 0),
                .init(color: .clear, location: 1)
            ]),
            center: CGPoint(x: rx * 0.34, y: -ry * 0.46),
            startRadius: 0, endRadius: iconR * 0.42
        ))

        // Draw eyes
        var eyeCtx = ctx
        eyeCtx.clip(to: bodyPath)
        let ink = Color(red: 0.102, green: 0.082, blue: 0.071)
        for f in mEyeFrames(mH) {
            guard f.visible else { continue }
            var ec = eyeCtx
            ec.translateBy(x: f.x, y: f.y)
            ec.scaleBy(x: f.fx, y: f.fy)
            let hh = max(f.h, f.w * 0.3)
            var pill = Path()
            pill.addRoundedRect(
                in: CGRect(x: -f.w / 2, y: -hh / 2, width: f.w, height: hh),
                cornerSize: CGSize(width: min(f.w / 2, hh / 2), height: min(f.w / 2, hh / 2))
            )
            ec.fill(pill, with: .color(ink))
        }

        // Draw outfit front
        drawOutfitFrontStatic(context: context, outfit: outfit, H: mH,
                              cx: cx, cy: iconCY, tilt: 0, sx: 1, sy: 1,
                              roll: 0, morph: 0, isMini: false)
    }
}
// MARK: - Card background

/// The colour wash behind a card. Lives outside `CardBackground` so views that
/// only need to name it — the inbox rows, which forward a wash they don't draw
/// — don't have to spell out the generic parameter.
enum CardWash { case red, green, pink, amber, cyan, indigo, soft }

struct CardBackground<Content: View>: View {
    let wash: CardWash?
    let content: (() -> Content)?

    init(wash: CardWash?, @ViewBuilder content: @escaping () -> Content) {
        self.wash = wash
        self.content = content
    }

    var washColor: Color {
        switch wash {
        case .red:    return Color(hex: "#F4505E").opacity(0.55)
        case .green:  return Color(hex: "#34D399").opacity(0.5)
        case .pink:   return Color(hex: "#F472B6").opacity(0.55)
        case .amber:  return Color(hex: "#F5A524").opacity(0.42)
        case .cyan:   return Color(hex: "#22D3EE").opacity(0.38)
        case .indigo: return Color(hex: "#6366F1").opacity(0.5)
        case .soft:   return Color.white.opacity(0.08)
        case nil:     return Color.clear
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )

            if let content = content {
                content()
            }
        }
    }
}

extension CardBackground where Content == EmptyView {
    init(wash: CardWash?) {
        self.wash = wash
        self.content = nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )
        }
    }
}

// MARK: - Shared sub-components

struct AgentWho: View {
    let task: AgentTask?
    /// The session's own name, when there is one. "Claude Code" is the name of
    /// the tool every session comes from; the session's name is what tells two
    /// of them apart.
    let name: String?
    let label: String

    init(task: AgentTask?, name: String? = nil, label: String) {
        self.task = task
        self.name = name
        self.label = label
    }

    var body: some View {
        HStack(spacing: 7) {
            if let task = task {
                Circle().fill(Color(hex: task.color)).frame(width: 8, height: 8)
            }
            if let name = name, !name.isEmpty {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            } else if let task = task {
                Text(task.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            }
            Text(LocalizedStringKey(label)).font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundColor(Color(hex: "#E8E9EC"))
    }
}


struct ShimmeringText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: "#7c818a"), location: 0),
                        .init(color: .white, location: 0.4),
                        .init(color: Color(hex: "#7c818a"), location: 0.7)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0.0

    var body: some View {
        LinearGradient(
            stops: [
                // Clamp all locations to [0,1] and keep them ordered
                .init(color: .clear,                   location: max(0, phase - 0.3)),
                .init(color: Color.white.opacity(0.6), location: max(0, min(1, phase))),
                .init(color: .clear,                   location: min(1, phase + 0.3))
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .blendMode(.overlay)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                phase = 1.3  // travels left→right, exits right edge cleanly
            }
        }
    }
}

// MARK: - Button styles

struct PrimaryButton: View {
    let title: String
    let verbatim: Bool
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = false; self.kbd = kbd; self.action = action
    }

    init(verbatim title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = true; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if verbatim { Text(verbatim: title) } else { Text(LocalizedStringKey(title)) }
                }.font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color(hex: "#F5F6F8"))
            .foregroundColor(Color(hex: "#0B0C0E"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    let verbatim: Bool
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = false; self.kbd = kbd; self.action = action
    }

    init(verbatim title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.verbatim = true; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if verbatim { Text(verbatim: title) } else { Text(LocalizedStringKey(title)) }
                }.font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color.white.opacity(0.09))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.08))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color(hex: "#F5F6F8"))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// MARK: - Color extension (lighten)

// MARK: - Chat-provider switch (used by AI pill buttons and ↗ action)


extension Color {
    func lighter(by amount: Double) -> Color {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(
            red: min(1, Double(components.redComponent) + amount),
            green: min(1, Double(components.greenComponent) + amount),
            blue: min(1, Double(components.blueComponent) + amount)
        )
    }
}
