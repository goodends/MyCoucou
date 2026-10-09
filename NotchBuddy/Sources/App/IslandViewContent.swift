import SwiftUI

// MARK: - Dispatch view content by IslandView

struct IslandViewContent: View {
    let view: IslandView
    @ObservedObject var state: AppState

    var body: some View {
        switch view {
        case .overview:  OverviewView(state: state)
        case .empty:     EmptyStateView(state: state)
        case .approval:  ApprovalView(state: state)
        case .question:  QuestionView(state: state)
        case .error:     ErrorView(state: state)
        case .finished:  FinishedView(state: state)
        case .confused:  ConfusedView()
        case .upload:    UploadView(state: state)
        case .uploading: UploadingView(state: state)
        case .choose:    ChooseView(state: state)
        case .mail:      MailView(state: state)
        case .prompt:    PromptView(state: state)
        case .searching: SearchingView(state: state)
        case .result:    ResultView(state: state)
        case .note:      NoteView(state: state)
        case .settings:  SettingsIslandView(state: state)
        case .greeting:  EmptyView()  // GreetingCanvasView overlaid in IslandRootView
        case .wardrobe:  WardrobeView(state: state)
        case .recap:     WeeklyRecapCardView(state: state)
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var activeDiffId: Int? = nil

    /// Left card shows the most-recently-active Claude session when there is
    /// one. Falls back to the focus task for the no-Claude-session case.
    var agent: AgentTask? {
        if let s = state.overviewSession { return state.overviewTask(for: s) }
        return state.focusTask
    }

    var body: some View {
        HStack(spacing: 10) {
            // Left card: title row + ticker below + ↗ button overlay
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)

                // Title row + ticker stacked
                if let agent = agent {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: ClaudeSessionPill.stateDotColor(for: agent.state)))
                                .frame(width: 7, height: 7)
                            Text(agent.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(hex: "#F5F6F8"))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
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
                            Spacer(minLength: 2)
                            if agent.steps.count > 1 {
                                Text("\(min(agent.stepIndex + 1, agent.steps.count))/\(agent.steps.count)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#6B7079"))
                                    .fixedSize()
                            }
                        }
                        .padding(.top, 6)
                        .padding(.leading, 108)
                        .padding(.trailing, 36)

                        TickerView(task: agent, onDiffTap: { diffIdx in
                            withAnimation(.easeIn(duration: 0.16)) { activeDiffId = diffIdx }
                        })
                            .frame(height: 44)
                            .padding(.top, 6)
                            .padding(.leading, 108)
                            .padding(.trailing, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
                }

                // Plan detail overlays on top of normal content (GitHub build, home view only)
                #if !APPSTORE
                if state.showingPlanDetail {
                    CardBackground(wash: nil)
                    Group {
                        if state.planDetailIsCodex {
                            CodexPlanCardView(usage: state.codexPlanUsage)
                        } else {
                            ClaudePlanCardView(usage: state.claudePlanUsage)
                        }
                    }
                    .transition(.opacity)
                }
                #endif

                // Diff overlay — replaces ticker when a diff step is tapped
                if let diffId = activeDiffId,
                   let task = agent,
                   let diff = state.sessionDiffs[task.id]?.first(where: { $0.id == diffId }) {
                    CardBackground(wash: nil)
                    DiffCardView(diff: diff, onDismiss: { activeDiffId = nil })
                        .transition(.opacity)
                }

                // ↗ jump button — last in ZStack so it renders on top; hidden while any detail is open
                #if !APPSTORE
                let hideJumpButton = state.showingPlanDetail || activeDiffId != nil
                #else
                let hideJumpButton = activeDiffId != nil
                #endif
                if !hideJumpButton {
                    Button(action: { openAgentTarget(agent) }) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(Color(hex: "#5F646D"))
                            .frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let task = state.focusTask, PillCatalog.isChatablePill(id: task.id) {
                    // Mirror right-card pill tap: lock the chat to the current
                    // overview session so its host shows in the bottom-right label
                    // (e.g. "Orca") instead of falling back to the global tasks[].
                    if let s = state.overviewSession { state.focusedSessionId = s.sessionId }
                    state.view = .prompt
                }
            }
            .frame(width: 322)

            // Right card: agent pills
            CardBackground(wash: nil) {
                ClaudeSessionsListView(state: state)
            }
        }
        .onChange(of: state.focusId) { _, _ in
            activeDiffId = nil
            #if !APPSTORE
            withAnimation(.easeIn(duration: 0.16)) { state.showingPlanDetail = false }
            #endif
        }
        #if !APPSTORE
        .onChange(of: state.view) { _, v in
            if v != .overview { state.showingPlanDetail = false; activeDiffId = nil }
        }
        #endif
        .onChange(of: state.mode) { _, m in
            #if !APPSTORE
            if m != .expanded { state.showingPlanDetail = false; activeDiffId = nil }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandToggleDiff)) { _ in
            if let id = activeDiffId {
                withAnimation(.easeIn(duration: 0.16)) { activeDiffId = nil }
                _ = id
            } else if let task = state.focusTask,
                      let last = state.sessionDiffs[task.id]?.last {
                withAnimation(.easeIn(duration: 0.16)) { activeDiffId = last.id }
            }
        }
    }

    private func openAgentTarget(_ task: AgentTask?) {
        guard let task else { return }
        // Orca first: if Orca hosts this session, switch to its exact
        // terminal tab instead of merely raising the app.
        Task { @MainActor in
            if await state.jumpToOrcaTerminal() { return }
            activateHostApp(for: task)
        }
    }

    /// Fallback for when Orca doesn't host the session: raise the app that
    /// runs it (VS Code, Cursor, a terminal, …).
    private func activateHostApp(for task: AgentTask) {
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
                    // Header row: agent name + question counter + "Reply in terminal" link
                    HStack(spacing: 4) {
                        AgentWho(task: nil, label: "Claude Code is asking")
                        Spacer(minLength: 4)
                        if q.questions.count > 1 {
                            Text("\(qi + 1)/\(q.questions.count)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#6B7079"))
                        }
                        Button("Reply in terminal") { HookServer.shared.sendQuestionAsk() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                            .underline()
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
                            .onSubmit { commitOtherAndProceed(q: q, qi: qi, isLast: isLast) }
                            .onExitCommand { if qi < showOther.count { showOther[qi] = false } }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button(isLast ? "Send" : "Next") {
                                commitOtherAndProceed(q: q, qi: qi, isLast: isLast)
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
                                        selectAndProceed(q: q, qi: qi, label: opt.label, isLast: isLast)
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
                                        selectAndProceed(q: q, qi: qi, label: opt.label, isLast: isLast)
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
                    // Send/Next — only for multi-select (and not while "Other…" field is open)
                    if isMulti && !curOther {
                        PrimaryButton(isLast ? "Send" : "Next") {
                            proceedFromQuestion(q: q, qi: qi, isLast: isLast)
                        }
                        .disabled(!canProceed)
                        .opacity(canProceed ? 1 : 0.4)
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
    private func selectAndProceed(q: AskQuestion, qi: Int, label: String, isLast: Bool) {
        guard qi < selections.count else { return }
        selections[qi] = [label]
        if isLast { sendAnswers(q: q) } else { withAnimation { questionIndex = qi + 1 } }
    }

    // Multi-select Send/Next button
    private func proceedFromQuestion(q: AskQuestion, qi: Int, isLast: Bool) {
        if isLast { sendAnswers(q: q) } else { withAnimation { questionIndex = qi + 1 } }
    }

    // "Other…" confirm
    private func commitOtherAndProceed(q: AskQuestion, qi: Int, isLast: Bool) {
        let text = qi < otherTexts.count ? otherTexts[qi] : ""
        guard !text.isEmpty else { return }
        if qi < selections.count { selections[qi] = [text] }
        if isLast {
            sendAnswers(q: q)
        } else {
            if qi < showOther.count { showOther[qi] = false }
            withAnimation { questionIndex = qi + 1 }
        }
    }

    private func sendAnswers(q: AskQuestion) {
        let answers = AskQuestion.buildAnswers(questions: q.questions, selections: selections)
        HookServer.shared.sendQuestionAnswers(answers)
    }
}

// MARK: - Error

struct ErrorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: .red)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "n8n")
                Text("Workflow stopped.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Gmail node timed out after 30s. Retry or open n8n.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#FF8D97"))
                HStack(spacing: 8) {
                    PrimaryButton("Retry") { /* retry */ }
                    SecondaryButton("Open in n8n") { /* open */ }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

struct FinishedView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: .green)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "Claude Code finished")
                Text({
                    if let fl = state.focusTask?.finalLine { return fl }
                    if let s = state.focusTask?.steps.last(where: { !$0.isDiffStep }) { return s }
                    return String(localized: "Session finished")
                }())
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    if state.focusTask?.id == "agent_claude-desktop" {
                        // Sessions from the Claude desktop app live there, not in a terminal.
                        PrimaryButton("Open Claude") {
                            openClaudeDesktopApp()
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        }
                    } else {
                        #if !APPSTORE
                        PrimaryButton("Open terminal") {
                            let task = state.focusTask
                            Task { @MainActor in
                                // Orca hosts this session → jump to its exact tab.
                                if await state.jumpToOrcaTerminal() { return }
                                // Otherwise raise the app the session runs in
                                // (its terminal, or VS Code), then any known terminal.
                                if !(task?.id == "integration_claude" && ClaudeHost.activate(task?.hostApp)),
                                   !TerminalTarget.activate(sessionBundleId: task?.sessionBundleId) {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                                }
                            }
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        }
                        #endif
                    }
                    SecondaryButton("OK") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
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

// MARK: - Upload (drop zone)

struct UploadView: View {
    @ObservedObject var state: AppState
    @State private var dashPhase: CGFloat = 0
    @State private var breathAngle: Double = 0
    // Timer only runs while this is the active tab — killed on deactivation
    @State private var animTimer: Timer? = nil

    private var borderOpacity: Double {
        let breathe = 0.11 + 0.04 * (sin(breathAngle) * 0.5 + 0.5)
        return state.fileDragOver ? 0.65 : breathe
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#0E0F11"))
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    state.fileDragOver
                        ? Color(hex: "#22C55E").opacity(borderOpacity)
                        : Color.white.opacity(borderOpacity),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5], dashPhase: dashPhase)
                )
            RoundedRectangle(cornerRadius: 20)
                .fill(RadialGradient(
                    colors: [Color(hex: "#22C55E").opacity(state.fileDragOver ? 0.13 : 0), Color.clear],
                    center: .bottom, startRadius: 0, endRadius: 200
                ))
            VStack(alignment: .leading, spacing: 8) {
                Text("Drop your files here")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(state.fileDragOver ? Color(hex: "#34D399") : Color(hex: "#D5D7DB"))
                HStack(spacing: 6) {
                    ForEach(["PDF", "Images", "Code", "Docs"], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.07))
                            .foregroundColor(Color(hex: "#B9BDC4"))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.leading, 196)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: state.view) { _, newView in
            newView == .upload ? startTimer() : stopTimer()
        }
        .onAppear {
            if state.view == .upload { startTimer() }
        }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard animTimer == nil else { return }
        // 20 fps — smooth enough for slow dash, 3× lighter than 60fps
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0/20.0, repeats: true) { _ in
            dashPhase  += 1.0          // 20 pt/s march
            breathAngle += 0.9 / 20.0  // advance sin phase at 0.9 rad/s
        }
    }

    private func stopTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }
}

// MARK: - Uploading

struct UploadingView: View {
    @ObservedObject var state: AppState

    // Bar geometry in content coords (content has 10pt H padding each side).
    // Island bar: left=36, right=562 (640-78), width=526.
    // Content bar: left=26, width=526.
    // barTop=58 → island y = content_start(42)+58 = 100; bot cy=103 (center = barTop+3).
    private let barLeft: CGFloat  = 26
    private let barWidth: CGFloat = 526
    private let barTop: CGFloat   = 58

    var body: some View {
        // TimelineView fires at display refresh rate — progress derived from elapsed wall time,
        // not from @Published uploadProgress (which only flips to 1.0 at completion).
        TimelineView(.animation) { tl in
            let elapsed: Double = {
                guard let start = state.uploadStartTime else { return 0 }
                return tl.date.timeIntervalSince(start)
            }()
            let t        = min(1.0, max(0, elapsed / state.uploadDuration))
            let progress = CGFloat(t * (2 - t))          // ease-out quad
            let fillWidth = max(0, barWidth * progress)
            let isDone   = state.uploadProgress >= 0.999  // only true after handle() sets it

            ZStack(alignment: .topLeading) {
                // Background: dark base
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: "#141518"))

                // Permanent green radial wash — brighter at completion
                RoundedRectangle(cornerRadius: 20)
                    .fill(RadialGradient(
                        colors: [Color(hex: "#34D399").opacity(isDone ? 0.28 : 0.14), Color.clear],
                        center: UnitPoint(x: 0.5, y: 1.4),
                        startRadius: 0,
                        endRadius: 260
                    ))

                // Bar track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.09))
                    .frame(width: barWidth, height: 6)
                    .offset(x: barLeft, y: barTop)

                // Bar fill
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [Color(hex: "#1FA87A"), Color(hex: "#34D399")],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: fillWidth, height: 6)
                    .offset(x: barLeft, y: barTop)

                // Glow trail behind dot leading edge
                if progress > 0.01 {
                    Ellipse()
                        .fill(Color(hex: "#6EE7B7").opacity(0.45))
                        .frame(width: 28, height: 12)
                        .blur(radius: 5)
                        .offset(x: barLeft + fillWidth - 14, y: barTop - 3)
                }

                // Text row — filename + % (above bar)
                HStack(spacing: 0) {
                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#34D399"))
                        Text("  \(state.droppedFile?.name ?? "File")")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#34D399"))
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(String(format: String(localized: "Uploading %@"), state.droppedFile?.name ?? "file"))
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "#A9ADB5"))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(Int(progress * 100)) %")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(Color(hex: "#A9ADB5"))
                            .monospacedDigit()
                    }
                }
                .frame(width: barWidth)
                .offset(x: barLeft, y: barTop - 22)

                // Subtle top border (same as CardBackground)
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.035), lineWidth: 1)
            }
        }
    }
}

// MARK: - Choose

struct ChooseView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 8) {
                let fileName = state.droppedFile?.name ?? "file"
                Text(String(format: String(localized: "file.ready %@"), fileName))
                    .font(.system(size: 14, weight: .semibold))
                Text("What do you want to do with it?").font(.system(size: 12.5)).foregroundColor(Color(hex: "#9398A1"))
                HStack(spacing: 8) {
                    PrimaryButton("Ask a question") { state.view = .prompt }
                    SecondaryButton("Send by email") { state.view = .mail }
                }
            }
            .padding(.leading, 98)
            .padding(.trailing, 18)
        }
    }
}

// MARK: - Mail

struct MailView: View {
    @ObservedObject var state: AppState
    @State private var to: String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var statusMsg: String = ""
    @State private var isSending = false

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("New email").font(.system(size: 12, weight: .semibold))
                    if let name = state.droppedFile?.name {
                        Text(String(format: String(localized: "mail.with %@"), name))
                            .font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                MailField(label: "To", placeholder: "address@example.com", text: $to)
                MailField(label: "Subject", placeholder: state.droppedFile?.name ?? "Subject", text: $subject)

                // Body — TextEditor scrolls internally when text overflows
                TextEditor(text: $bodyText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if !statusMsg.isEmpty {
                    Text(statusMsg).font(.system(size: 11)).foregroundColor(Color(hex: "#FF8D97"))
                }

                HStack(spacing: 8) {
                    PrimaryButton(verbatim: isSending ? String(localized: "Sending…") : String(localized: "Send")) {
                        guard !isSending else { return }
                        sendMail()
                    }
                    SecondaryButton("Cancel") { state.view = .choose }
                }
            }
            .padding(.leading, 92)
            .padding(.trailing, 18)
            .padding(.vertical, 8)
        }
        .onAppear { subject = state.droppedFile?.name ?? "" }
    }

    private func sendMail() {
        guard !to.isEmpty else { statusMsg = String(localized: "Missing recipient."); return }
        let subj = subject.isEmpty ? (state.droppedFile?.name ?? "File") : subject
        sendViaAppleMail(to: to, subject: subj)
    }

    private func sendViaAppleMail(to: String, subject: String) {
        #if APPSTORE
        // App Store: no AppleScript — use NSSharingService to compose (user sends manually)
        guard let service = NSSharingService(named: .composeEmail) else {
            statusMsg = String(localized: "Mail not available.")
            return
        }
        var items: [Any] = [bodyText.isEmpty ? " " : bodyText]
        if let url = state.droppedFile?.url,
           FileManager.default.fileExists(atPath: url.path) {
            items.append(url)
        }
        service.recipients = [to]
        service.subject = subject
        service.perform(withItems: items)
        onSuccess(recipient: to)
        #else
        func asEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }

        let bodyLines = bodyText.isEmpty ? [""] : bodyText.components(separatedBy: "\n")
        let bodyExpr = bodyLines.map { "\"\(asEscape($0))\"" }.joined(separator: " & linefeed & ")
            + " & return & return"

        let attachBlock: String
        if let url = state.droppedFile?.url,
           FileManager.default.fileExists(atPath: url.path) {
            let escapedPath = asEscape(url.path)
            attachBlock = "make new attachment with properties {file name:(POSIX file \"\(escapedPath)\")} at after the last paragraph of content"
        } else {
            attachBlock = ""
        }

        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {subject:"\(asEscape(subject))", visible:false}
            set content of m to \(bodyExpr)
            tell m
                make new to recipient at end of to recipients with properties {address:"\(asEscape(to))"}
                \(attachBlock)
            end tell
            delay 1
            send m
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err == nil { onSuccess(recipient: to) }
        else { statusMsg = "Mail error: \(err?["NSAppleScriptErrorMessage"] as? String ?? "unknown")" }
        #endif
    }

    private func onSuccess(recipient: String) {
        SoundEngine.shared.play("send")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.wink)
        state.noteMessage = "Email sent to \(recipient)."
        state.view = .note
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }
}

// MARK: - Prompt (chat)

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

    private var historyBinding: [HistoryEntry] {
        state.focusTask?.history ?? []
    }

    private var focusTaskLabel: String {
        // 1. The session the user explicitly tapped into (right-card pill tap, or
        //    a follow-up left-card tap after the first SessionStart has populated
        //    its hostApp/sessionBundleId).
        if let s = state.focusedClaudeSession {
            return ClaudeHost.name(for: s.hostApp ?? s.sessionBundleId)
        }
        // 2. The session driving the left card (matches what the user just saw
        //    on the home view, even on the very first click before any tap has
        //    set focusedSessionId).
        if let s = state.overviewSession {
            return ClaudeHost.name(for: s.hostApp ?? s.sessionBundleId)
        }
        // 3. Last-resort: the global integration_claude task's most-recent host
        //    (may be stale from a previous terminal session).
        guard let task = state.focusTask else { return "Claude Code" }
        if task.id == "integration_claude" {
            return ClaudeHost.name(for: task.hostApp ?? task.sessionBundleId)
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

                HStack(spacing: 0) {
                    Spacer()
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
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
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
        .padding(.bottom, 10)
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
        text = ""

        // Append the prompt locally so the user sees it immediately, then
        // hand it to Orca to type into the running agent. When Orca can't
        // reach the session we keep the local echo but flag it as not sent.
        if let task = state.focusTask,
           let idx = state.tasks.firstIndex(where: { $0.id == task.id }) {
            state.tasks[idx].history.append(HistoryEntry(role: .user, content: query))
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

struct TickerView: View {
    let task: AgentTask?
    var onDiffTap: ((Int) -> Void)? = nil

    @State private var rowA: String = "…"   // completed (above, left-shifted)
    @State private var rowB: String = "…"   // current (below) → animates diagonally up-left
    @State private var rowC: String = ""    // incoming current — slides in from below

    @State private var rowAOffset: CGFloat = 0
    @State private var rowAOpacity: Double = 1
    @State private var rowBOffset: CGFloat = 22
    @State private var rowBPhase:  Double  = 0   // 0=current, 1=completed (drives X+scale)
    @State private var rowCOffset: CGFloat = 44
    @State private var rowCOpacity: Double = 0

    @State private var displayIndex: Int = -1
    @State private var isTransitioning = false

    private let completedScale: CGFloat = 11.5 / 13   // 0.885 — matches completed font size

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

            // Row A: completed row — always rendered at phase=1 + completedScale
            TickerRowView(text: rowA, phase: 1.0, isActive: isActive, onDiffTap: rowADiffTap)
                .scaleEffect(completedScale, anchor: .leading)
                .offset(x: -10, y: rowAOffset)
                .opacity(rowAOpacity)

            // Row B: current step → animates diagonally up-left, phase 0→1, scale 1→completedScale
            TickerRowView(text: rowB, phase: rowBPhase, isActive: isActive, onDiffTap: rowBDiffTap)
                .scaleEffect(1 - rowBPhase * (1 - completedScale), anchor: .leading)
                .offset(x: -rowBPhase * 10, y: rowBOffset)

            // Row C: incoming new step — slides in from below at phase=0
            TickerRowView(text: rowC, phase: 0.0, isActive: isActive)
                .offset(y: rowCOffset)
                .opacity(rowCOpacity)
        }
        .frame(height: 44)
        .clipped()
        .mask(LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        ))
        .onAppear {
            let idx = task?.stepIndex ?? -1
            displayIndex = idx
            if idx >= 0, !steps.isEmpty {
                rowA = idx > 0 ? steps[max(0, idx - 1)] : "…"
                rowB = steps[min(idx, steps.count - 1)]
            }
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

    private func tickerAnimate(to newIdx: Int) {
        isTransitioning = true
        rowC = steps[min(newIdx, steps.count - 1)]
        rowCOffset = 44
        rowCOpacity = 0

        // Old completed (rowA): fades + slides further up
        withAnimation(.easeOut(duration: 0.28)) {
            rowAOffset  = -22
            rowAOpacity = 0
        }

        // Current (rowB): moves diagonally up-left + shrinks to completed size
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowBOffset = 0
            rowBPhase  = 1
        }

        // New current (rowC): slides in from below
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowCOffset  = 22
            rowCOpacity = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            self.displayIndex    = newIdx
            self.rowA            = self.rowB
            self.rowAOffset      = 0
            self.rowAOpacity     = 1
            self.rowB            = self.rowC
            self.rowBOffset      = 22
            self.rowBPhase       = 0
            self.rowCOffset      = 44
            self.rowCOpacity     = 0
            self.isTransitioning = false
        }
    }
}

struct TickerRowView: View {
    let text: String
    let phase: Double   // 0 = current (shimmer, large), 1 = completed (dim, scaled down by caller)
    var isActive: Bool = true
    var onDiffTap: (() -> Void)? = nil

    var body: some View {
        let chevronOpacity:   Double = isActive ? max(0, 1 - phase * 2)       : 0
        let checkmarkOpacity: Double = isActive ? max(0, phase * 2 - 1)       : 1
        let shimmerOpacity:   Double = isActive ? max(0, 1 - phase * 1.6)     : 0
        let staticOpacity:    Double = isActive ? min(1, max(0, phase * 2 - 0.4)) : 1
        let staticColor = (!isActive && phase < 0.5) ? Color(hex: "#C9CDD4") : Color(hex: "#6B7079")

        if let dp = text.parseDiffStep() {
            HStack(spacing: 6) {
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
                        TickerShimmerText(text: dp.filename)
                            .opacity(shimmerOpacity)
                        Text(dp.filename)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(staticColor)
                            .lineLimit(1).truncationMode(.tail)
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
            .frame(height: 22, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onDiffTap?() }
        } else {
            HStack(spacing: 6) {
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
                    TickerShimmerText(text: text)
                        .opacity(shimmerOpacity)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(staticColor)
                        .lineLimit(1).truncationMode(.tail)
                        .opacity(staticOpacity)
                }
            }
            .frame(height: 22, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TickerShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2)
            // phase sweeps -0.1 → 1.1 so white peak enters from left and exits right
            let phase = p * 1.2 - 0.1
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
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
            state: botState(for: session.state),
            steps: [],
            source: .claudeCode,
            outfit: session.outfit
        )
    }

    /// Under the project name: just the host terminal (the project name is
    /// already the title above, so repeating the cwd here was redundant).
    private var subtitle: String {
        ClaudeHost.name(for: session.hostApp ?? session.sessionBundleId)
    }

    private func botState(for phase: SessionPhase) -> BotState {
        switch phase {
        case .spawning: return .thinking
        case .working:  return .working
        case .finished: return .finished
        case .stopped:  return .idle
        }
    }

    private var stateDotColor: String {
        Self.stateDotColor(for: botTask.state)
    }

    /// Shared mapping so the overview's left card and the right-card pill
    /// show the same status colour for the same session. Takes BotState
    /// (already-mapped from SessionPhase inside `botTask`) so it lines up
    /// with the overview card's `AgentTask.state` field too.
    static func stateDotColor(for state: BotState) -> String {
        switch state {
        case .thinking:   return "#5EEAD4"  // cyan  (spawning)
        case .working:    return claudeColor
        case .finished:   return "#22C55E"  // green
        case .idle:       return "#5F646D"  // dim   (stopped)
        default:          return "#5F646D"  // searching / approval / question / error / ratelimit / sleeping / dizzy
        }
    }

    private var showsTypingDots: Bool {
        switch botTask.state {
        case .working, .thinking: return true
        default: return false
        }
    }

    var body: some View {
        Button(action: { onTap() }) {
            ZStack(alignment: .topTrailing) {
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
                        Text(session.projectName)
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
                    .padding(.trailing, 18)
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .shadow(color: Color(hex: Self.claudeColor).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)

                Circle()
                    .fill(Color(hex: stateDotColor))
                    .frame(width: 6, height: 6)
                    .offset(x: -6, y: 4)
                    .allowsHitTesting(false)
                if showsTypingDots {
                    TypingDotsView()
                        .offset(x: -22, y: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .onHover { newHover in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
        // Right-click opens the wardrobe for this session. The wardrobe's
        // current outfit is bound to `state.overviewSession.outfit`, so
        // editing there — or swiping back and right-clicking another pill —
        // always lands on the same value.
        .contextMenu {
            Button {
                state.view = .wardrobe
            } label: {
                Label("Change outfit…", systemImage: "tshirt")
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

    /// 30-min idle threshold for zombie sessions (killed Claude process with no SessionEnd).
    private static let idleCutoff: TimeInterval = 30 * 60

    private var live: [ClaudeSession] {
        let cutoff = Date().addingTimeInterval(-Self.idleCutoff)
        return state.claudeSessions.filter { $0.lastEventAt >= cutoff }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if live.isEmpty {
                // No active Claude session — leave the right card empty.
                // The previous fallback to AgentPillsView (Cursor / Codex /
                // Gemini / …) is gone: this view only renders Claude work.
                EmptyView()
            } else {
                // Two columns, scrollable so 4+ sessions don't get crushed by
                // the island's fixed height. No border / indicator — the right
                // card already sits inside its own CardBackground.
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 4),
                                        GridItem(.flexible(), spacing: 4)],
                              alignment: .leading,
                              spacing: 4) {
                        ForEach(live) { s in
                            ClaudeSessionPill(session: s, state: state) { tap(s) }
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.78), value: live.count)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tap(_ s: ClaudeSession) {
        guard !swapping else { return }
        swapping = true
        SoundEngine.shared.play("blip")
        // Open the chat view for this session. PromptView swaps its in-memory
        // history for ChatSessionView's JSONL stream when focusedClaudeSession is set.
        state.focusedSessionId = s.sessionId
        state.view = .prompt
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
        case .finished: return Color(hex: "#22C55E")
        case .error:    return Color(hex: "#F4505E")
        }
    }

    private var icon: String {
        switch badge {
        case .approval: return "exclamationmark"
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

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 5), count: 14)

    /// The outfit currently displayed on the right pill / main Mochi.
    /// Driven by the active `overviewSession` so editing here and right-clicking
    /// a pill on the right card both edit the same value.
    private var currentOutfit: Outfit {
        state.overviewSession?.outfit ?? .none
    }

    private var headerRight: String {
        // Hover takes priority: show hovered outfit name
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
        }
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            state.wardrobePreviewOutfit = nil
            hoveredOutfit = nil
        }
        .onExitCommand {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = .overview
            }
        }
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
        let pumpkin = outfit == .pumpkin
        let top = pumpkin ? Color(hex: "#FFA94D") : Color(red: 0.929, green: 0.929, blue: 0.937)
        let bot = pumpkin ? Color(hex: "#E8590C") : Color(red: 0.769, green: 0.773, blue: 0.792)
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


struct MailField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#80858E"))
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#F5F6F8"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

// MARK: - Settings island view (Point 7)

struct SettingsIslandView: View {
    @ObservedObject var state: AppState

    private var claudeConnected: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let ss = hooks["SessionStart"] as? [[String: Any]] else { return false }
        return ss.contains { matcher in
            (matcher["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 10) {
                // Sound row
                HStack(spacing: 10) {
                    Toggle("", isOn: $state.soundEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.75)
                        .frame(width: 44)
                    Text("Sound")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Slider(value: $state.soundVolume, in: 0...0.2)
                        .frame(width: 72)
                        .opacity(state.soundEnabled ? 1 : 0.4)
                }

                // Auto-close row
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 16)
                    Text(String(format: String(localized: "Auto-close · %llds"), Int64(state.autoCloseInterval)))
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach([10, 15, 30], id: \.self) { s in
                            Button("\(s)s") {
                                state.autoCloseInterval = Double(s)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(state.autoCloseInterval == Double(s) ? Color(hex: "#252830") : Color.clear)
                            .foregroundColor(state.autoCloseInterval == Double(s) ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
                            .clipShape(Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Connection status
                HStack(spacing: 14) {
                    StatusBadge(label: "Claude Code", ok: claudeConnected)
                    Spacer()
                    Button("Settings…") {
                        NotificationCenter.default.post(name: .openFullSettings, object: nil)
                    }
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
        }
    }
}

struct StatusBadge: View {
    let label: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
        }
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
