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
        case .confused:  ConfusedView()
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
            activateHostApp(for: task)
        }
    }

    /// Fallback for when Orca doesn't host the session: raise the app that
    /// runs it (VS Code, Cursor, a terminal, …).
    private static func activateHostApp(for task: AgentTask) {
        switch task.id {
        case "integration_claude":
            if ClaudeHost.activate(task.hostApp) { return }
            let vscodeBundleId = "com.microsoft.VSCode"
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == vscodeBundleId }) {
                app.activate(options: .activateIgnoringOtherApps)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))
            }
        case "agent_cursor":
            #if !APPSTORE
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
            #endif
        case "agent_codex":
            #if !APPSTORE
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
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

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var activeDiffId: Int? = nil

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

    var body: some View {
        HStack(spacing: 10) {
            // Left card: title row + ticker below + ↗ button overlay
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)

                // Title row + ticker stacked
                if let agent = agent {
                    VStack(alignment: .leading, spacing: 0) {
                        // Two lines: the name with its step count, the source
                        // under it. Sharing one line meant the source lost —
                        // "Claude Code" came out as "Claude C…" on every
                        // session whose name was more than a few characters.
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
                                if agent.steps.count > 1 {
                                    Text("\(min(agent.stepIndex + 1, agent.steps.count))/\(agent.steps.count)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "#6B7079"))
                                        .fixedSize()
                                }
                            }
                            Text({ () -> String in
                                switch agent.source {
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
                        .padding(.top, 6)
                        .padding(.leading, 108)
                        // Room for the jump arrow alone, plus the diff capsule
                        // when there is one. A fixed wide value would shorten the
                        // session name even on sessions that have never touched a
                        // file, for a badge that is not there.
                        .padding(.trailing, hasChangeTotals ? 96 : 36)

                        TickerView(task: agent, onDiffTap: { diffIdx in
                            withAnimation(.easeIn(duration: 0.16)) { activeDiffId = diffIdx }
                        })
                            // Breathing room between the title and the step
                            // below it. The ticker sizes itself to its text, so
                            // this is the only thing setting that gap.
                            .padding(.top, 0)
                            .padding(.leading, 108)
                            .padding(.trailing, 12)
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

                // ↗ jump + diff buttons — last in ZStack so they render on top; hidden
                // while a diff is open. Buttons, not part of the card's tap
                // gesture: a Button's gesture wins over the ancestor's, so each
                // one is clickable without also opening the chat.
                let hideJumpButton = activeDiffId != nil
                if !hideJumpButton {
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
                        Button(action: { AgentLauncher.open(agent, state: state) }) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(Color(hex: "#5F646D"))
                                .frame(width: 16, height: 16)
                                .background(Color.white.opacity(0.07))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
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
                // on the Diff button beside the jump arrow.
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
    }
}

// MARK: - Empty

struct EmptyStateView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nothing running right now.")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Drop a file or window, or ask me anything.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#9398A1"))
                }
                Spacer()
                PrimaryButton("Ask Claude") {
                    state.view = .prompt
                }
            }
            .padding(.leading, 118)
            .padding(.trailing, 18)
        }
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
                AgentWho(task: state.focusTask, label: "needs permission")
                CodeBlock(text: approval?.command ?? approval?.tool ?? "…")
                HStack(spacing: 8) {
                    SecondaryButton("Deny") {
                        HookServer.shared.sendApprovalDecision("deny")
                    }
                    PrimaryButton("Allow") {
                        HookServer.shared.sendApprovalDecision("allow")
                    }
                    // Codex, Copilot CLI and Muse Code do not support updatedPermissions
                    let hideAlways = approval?.pillId == "agent_codex"
                        || approval?.pillId == "agent_copilot"
                        || approval?.pillId == "agent_muse"
                    if !hideAlways {
                        SecondaryButton("Always") {
                            HookServer.shared.sendApprovalDecision("always")
                        }
                    }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        AgentWho(task: nil, label: "Claude Code is asking")
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
                        // left; Cancel and Submit are the two ways out of the
                        // last question, so they sit together on the right.
                        HStack(spacing: 8) {
                            SecondaryButton("Back") {
                                withAnimation { questionIndex = qi - 1 }
                            }
                            .disabled(qi == 0)
                            .opacity(qi == 0 ? 0.4 : 1)
                            Spacer(minLength: 0)
                            if isLast {
                                SecondaryButton("Cancel") { HookServer.shared.sendQuestionAsk() }
                            }
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
        InboxRow(state: state, pillId: question.pillId, sessionId: question.sessionId, botState: .question) {
            AgentWho(task: task, label: "Claude Code is asking")
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

/// A permission request waiting to be allowed or denied. Same shape: a row that
/// opens the real approval card, and a clock showing what's left of it.
private struct ApprovalInboxCard: View {
    let approval: PendingApproval
    @ObservedObject var state: AppState

    private var task: AgentTask? {
        state.tasks.first { $0.id == approval.info.pillId } ?? state.focusTask
    }

    var body: some View {
        InboxRow(state: state, pillId: approval.info.pillId, sessionId: approval.info.sessionId, botState: .approval) {
            AgentWho(task: task, label: "needs permission")
            Text(approval.info.command)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            InboxActions(
                deadline: approval.deadline,
                openLabel: String(localized: "Review"),
                onOpen: { HookServer.shared.openInboxItem(.approval(approval)) },
                onHandBack: { state.dismissInboxItem(.approval(approval)) }
            )
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
    @ViewBuilder let content: () -> Content

    /// 58pt Mochi vs the text beside it — the same size the finished card uses.
    private let botDiameter: CGFloat = 58

    private var session: ClaudeSession? {
        guard !sessionId.isEmpty else { return nil }
        return state.claudeSessions.first { $0.sessionId == sessionId }
    }

    var body: some View {
        CardBackground(wash: nil) {
            HStack(alignment: .center, spacing: 0) {
                BotCanvasView(state: state, sessionOverride: session, stateOverride: botState)
                    .frame(width: botDiameter / 0.6, height: botDiameter / 0.6)
                    .frame(width: botDiameter, height: botDiameter)
                    .padding(.leading, 28)
                    .padding(.trailing, 30)

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

    var body: some View {
        CardBackground(wash: isError ? .red : .green) {
            HStack(alignment: .center, spacing: 0) {
                BotCanvasView(state: state, sessionOverride: session,
                              stateOverride: isError ? .error : .finished)
                    .frame(width: Self.botDiameter / 0.6, height: Self.botDiameter / 0.6)
                    .frame(width: Self.botDiameter, height: Self.botDiameter)
                    .padding(.leading, 28)
                    .padding(.trailing, 30)

                VStack(alignment: .leading, spacing: 5) {
                    AgentWho(task: task, label: isError
                             ? String(localized: "Claude Code stopped early")
                             : String(localized: "Claude Code finished"))
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
                                let task = task
                                // Bind the jump to *this* card's session — its
                                // sessionId is the one with a verified Orca handle
                                // binding. Without this we fall through to the
                                // focused session, which may be a different Claude
                                // session in the same worktree and lands on the
                                // wrong Orca tab.
                                let sid = notification.sessionId
                                focusSession()
                                acknowledge()
                                Task { @MainActor in
                                    // Orca hosts this session → jump to its exact tab.
                                    if await state.jumpToOrcaTerminal(sessionId: sid) { return }
                                    // Otherwise raise the app the session runs in
                                    // (its terminal, or VS Code), then any known terminal.
                                    if !(task?.id == "integration_claude" && ClaudeHost.activate(task?.hostApp)),
                                       !TerminalTarget.activate(sessionBundleId: task?.sessionBundleId) {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                                    }
                                }
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

// MARK: - Confused

struct ConfusedView: View {
    var body: some View {
        ZStack {
            CardBackground(wash: .pink)
            VStack(alignment: .leading, spacing: 5) {
                Text("Too many hits at once.").font(.system(size: 15, weight: .semibold))
                Text("Give me a sec — back to work in three seconds.")
                    .font(.system(size: 13)).foregroundColor(Color(hex: "#9398A1"))
            }
            .padding(.leading, 128)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // Project picker — shown instead of the host chip when there's no live
    // session to jump to or type into. Picking a worktree starts a Claude Code
    // there and delivers `pendingPrompt` (the message the user had already
    // typed when they found out there was nowhere to send it).
    @State private var showProjectPicker = false
    @State private var startingInPath: String? = nil
    @State private var pendingPrompt: String? = nil

    /// A session the chat can actually reach: one Coucou has seen hook events
    /// from. Everything host-shaped in this view keys off this — without it the
    /// chips would be naming a process that isn't there.
    private var hasSession: Bool {
        state.focusedSessionId != nil || state.focusTask?.sessionId != nil
    }

    /// The picker stands in for the host chip when there's no session to name,
    /// and only where starting a session is actually possible.
    private var canPickProject: Bool {
        !hasSession && OrcaCLIBridge.isInstalled
    }

    private var projectPickerButton: some View {
        Button {
            showProjectPicker.toggle()
            if showProjectPicker { Task { await state.loadOrcaWorktrees() } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 9, weight: .medium))
                Text(String(localized: "Pick a project"))
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(Color(hex: "#7B8089"))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(chipHovered ? 0.12 : 0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { chipHovered = $0 }
        .help(String(localized: "Start a Claude Code session in a project"))
        // The chip sits near the bottom edge of the island, so the list opens upward
        // — flipping it round and down would hang it off the card.
        .popover(isPresented: $showProjectPicker, arrowEdge: .top) {
            projectPickerPopover
        }
    }

    private var projectPickerPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Start Claude Code in…"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#8E939C"))
            if state.orcaWorktreesLoading {
                Text(String(localized: "Loading…"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
            } else if let list = state.orcaWorktrees, !list.isEmpty {
                ForEach(list) { wt in
                    Button {
                        startSession(in: wt)
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
            } else {
                // Orca is installed but answered with nothing usable — say so
                // instead of showing a picker that can only fail.
                Text(String(localized: "No Orca projects found. Open one in Orca first."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(width: 220, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 260)
        // Popovers default to the system material — a light panel that clashes
        // with every other surface here. Same fill and hairline as
        // CardBackground so it reads as part of the island.
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )
        )
        .presentationBackground(Color(hex: "#141518"))
    }

    /// Spawn Claude Code in `wt` and deliver whatever the user had already typed
    /// when they found out there was nowhere to send it.
    private func startSession(in wt: OrcaWorktree) {
        let prompt = pendingPrompt
        pendingPrompt = nil
        text = ""
        startingInPath = wt.path
        Task { @MainActor in
            let ok = await state.startClaudeSession(in: wt.path, prompt: prompt)
            startingInPath = nil
            if ok {
                showProjectPicker = false
                showNotWiredToast = false
            } else {
                // Keep the words and the picker open: the user can retry, and
                // Claude Code really might not have come up.
                text = prompt ?? ""
                pendingPrompt = prompt
                showNotWiredToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { showNotWiredToast = false }
            }
        }
    }

    private var historyBinding: [HistoryEntry] {
        state.focusTask?.history ?? []
    }

    /// Which session the chat is bound to. `displayName` resolves to the
    /// user-set `customName` if they renamed the pill, otherwise the project
    /// folder name — the same string the home view shows.
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
                // displayName = customName if the user renamed the pill, else the
                // project folder name — the same string the home pill shows. Sits
                // at the top of the chat card, above the (small) Mochi on the left.
                if let name = chatSessionName {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#5F646D"))
                        Text(name)
                            .font(.system(size: 11.5, weight: .medium))
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
                    // With no live session there is no terminal to jump to and
                    // no host to name — both chips would lie. Offer the only
                    // action that does something real: start one.
                    if canPickProject {
                        projectPickerButton
                    }
                    #if !APPSTORE
                    if hasSession {
                        Button(action: { openChatTerminal() }) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(Color(hex: "#5F646D"))
                                .frame(width: 16, height: 16)
                                .background(Color.white.opacity(0.07))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Open terminal"))
                    }
                    #endif
                    // The chip names where the session runs, so it doubles as
                    // the jump — same action as the ↗ beside it.
                    if hasSession {
                        Button(action: { openChatTerminal() }) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: state.focusTask?.color ?? "#7B8089"))
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
        // which is worse than saying so. Keep the words, and let the user pick
        // a project to start one in — the pending prompt rides along.
        guard state.focusedSessionId != nil || state.focusTask?.sessionId != nil else {
            pendingPrompt = query
            showNotWiredToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { showNotWiredToast = false }
            if OrcaCLIBridge.isInstalled { showProjectPicker = true }
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
    /// The history row may use two, the current row below it four. Both are
    /// caps on the text, not slots it has to fill — a short step just takes
    /// fewer lines and the rows close up. The current row's cap is four rather
    /// than five so the card can carry 6pt of air above and below it without
    /// growing: the ticker's height is fixed from these two numbers, and the
    /// card is the tallest state by far, its top edge crowding the icons.
    static let historyLines = 2
    static let currentLines = 4
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
    @State private var isHovered = false

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
        .onTapGesture { onTap() }
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
                Label("Change outfit…", systemImage: "tshirt")
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

    /// Fallback threshold for sessions the relay gave us no pid for (an agent
    /// still on an older relay, or a parent chain it couldn't resolve). Only
    /// these age out — a session that reported a pid is judged by whether its
    /// process is still alive, never by how long ago the last event arrived:
    /// a session idling at the prompt fires no events at all, and used to
    /// vanish from here after 30 minutes while its process was perfectly fine.
    private static let idleCutoff: TimeInterval = 30 * 60

    private var live: [ClaudeSession] {
        let cutoff = Date().addingTimeInterval(-Self.idleCutoff)
        return state.claudeSessions.filter { s in
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
            if live.isEmpty {
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
                                        ClaudeSessionPill(session: s, state: state) { select(s) }
                                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
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
                // Nothing on the hook pipe at all can still mean a session is
                // running that started before us — re-check the process table
                // (rate-limited inside) so the card isn't just blank.
                if state.claudeSessions.isEmpty {
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

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 5), count: 14)

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

    /// Reads and writes the active session's name: same source as
    /// `currentOutfit` / `currentBodyColor`, so right-clicking another pill
    /// and coming back here edits that session.
    private var nameBinding: Binding<String> {
        Binding(
            get: { state.overviewSession?.customName ?? "" },
            set: { state.setSessionName(state.overviewSession?.sessionId ?? "", $0) }
        )
    }

    /// The grey line shown while the field is empty: says what happens then.
    /// It vanishes as soon as you type.
    private var emptyNameHint: String {
        String(localized: "Defaults to the project's name")
    }

    private var headerRight: String {
        // Hover takes priority: the colour pointed at, then the outfit.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("Wardrobe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Spacer(minLength: 4)
                Text(headerRight)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
            }
            .padding(.top, 6)
            .padding(.horizontal, 10)

            // Grid
            let allOutfits = Outfit.allCases.filter { $0 != .auto }
            let withAuto = [Outfit.auto] + allOutfits
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(withAuto, id: \.rawValue) { outfit in
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
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: .infinity)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.85),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )

            // Bottom row: the name the home view shows, then the Mochi's own
            // body colour. The outfit grid above scrolls; this strip stays put.
            // An empty name falls back to the project folder's name.
            Divider().overlay(Color.white.opacity(0.08))
                .padding(.top, 4)
            HStack(spacing: 10) {
                // The name reads as plain text until you point at it, when it
                // gains a background and brightens. The TextField is always in
                // the hierarchy — swapping a Text for a TextField on hover made
                // the pointer bounce in and out of hover, the same trap the
                // pill's jump button fell into.
                ZStack(alignment: .leading) {
                    // The hint is drawn by hand rather than left to the
                    // TextField's own placeholder: that one takes its colour
                    // from the system appearance, so on a black island in
                    // light mode it comes out black — invisible.
                    if (state.overviewSession?.customName ?? "").isEmpty {
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.white.opacity(nameHovered ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 180)
                .onHover { nameHovered = $0 }
                .help(emptyNameHint)
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
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 4)
        }
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

struct CardBackground<Content: View>: View {
    enum Wash { case red, green, pink, amber, cyan, indigo, soft }

    let wash: Wash?
    let content: (() -> Content)?

    init(wash: Wash?, @ViewBuilder content: @escaping () -> Content) {
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
    init(wash: Wash?) {
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
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            if let task = task {
                Circle().fill(Color(hex: task.color)).frame(width: 8, height: 8)
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
