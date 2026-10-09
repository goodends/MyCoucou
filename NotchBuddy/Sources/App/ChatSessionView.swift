import SwiftUI
import Darwin

/// Loads the JSONL for the tapped Claude Code session and renders it with the
/// same ChatBubble look as PromptView's history. Drops in as a substitute for
/// the in-memory `historyBinding` when a session pill is tapped.
struct ChatSessionView: View {
    @ObservedObject var state: AppState
    @State private var lines: [ChatLine] = []
    @State private var lastLoadedURL: String = ""
    /// File size at the time of the last successful parse. Used to detect when
    /// Claude Code has appended new tokens so we can re-parse (or hit the cache
    /// only when the on-disk file matches what we last parsed).
    @State private var lastLoadedSize: UInt64 = 0
    @State private var loadError: String? = nil
    /// Once we've opened the chat for a session, jump straight to the bottom
    /// without animating — no "scroll from top to bottom" reveal.
    @State private var hasOpenedOnce: Bool = false

    /// Parsed-JSONL cache, shared across ChatSessionView instances so re-opening
    /// the chat for a session we've already seen skips the parse step. Keyed by
    /// JSONL filename (the session id); the size lets us tell whether the cache
    /// entry is still current.
    private static var parsedCache: [String: (size: UInt64, lines: [ChatLine])] = [:]

    /// Kernel-level watcher on the JSONL file: fires within milliseconds of
    /// Claude Code writing new tokens, so the chat updates in real time
    /// instead of waiting for the 2 s polling fallback below.
    @State private var fileWatcher: DispatchSourceFileSystemObject?
    @State private var watchedFD: Int32 = -1
    @State private var watchedPath: String = ""

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Default cap on the rendered window so very long sessions don't burn CPU
/// materialising hundreds of ChatBubbles (and their parsed Markdown) on every
/// open. User can override via the "Load all" chip.
    private let defaultMaxRenderedLines = 80

    /// Whether the user opted in to render the entire session (no cap).
    @State private var showAllLines: Bool = false

    /// Which thinking / tool-call lines the user has expanded. Default
    /// collapsed — these blocks are usually long and would otherwise fill
    /// the notch. Inspired by cc-switch's "structured reading" rows: a one-
    /// line preview that opens on tap.
    @State private var expandedDetailIds: Set<UUID> = []

    /// Lines actually drawn. Always the tail of `lines` so the bottom stays
    /// current; the rest are summarised at the top with a fold-back chip.
    private var visibleLines: [ChatLine] {
        showAllLines ? lines : lines.suffix(defaultMaxRenderedLines)
    }
    private var hiddenCount: Int {
        max(0, lines.count - visibleLines.count)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let err = loadError {
                        Text(err)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "#F4505E"))
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                    }
                    if hiddenCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9))
                            Text("\(hiddenCount) earlier messages hidden")
                                .font(.system(size: 10))
                            Spacer()
                            Button(showAllLines ? "Hide history" : "Load all") {
                                showAllLines.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#5F8AFA"))
                        }
                        .foregroundColor(Color(hex: "#5F646D"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    ForEach(visibleLines) { line in
                        if line.role == .user || line.role == .assistant {
                            ChatBubble(message: ChatMessage(parsedLineRole: line.role.rawValue, content: line.content))
                                .id(line.id)
                        } else {
                            detailRow(line)
                                .id(line.id)
                        }
                    }
                    // Spacer so the bottom-anchored scroll leaves breathing room
                    // before the PromptView's input box instead of clipping the
                    // last message.
                    Color.clear.frame(height: 12)
                }
                .padding(.vertical, 2)
            }
            // Default anchor at the bottom. Eager VStack means the view has full
            // height before scrollTo runs, so re-opening a session always lands
            // on the last message — no scroll-up animation.
            .defaultScrollAnchor(.bottom)
            .reportsScrollAtBottomViaGeometry(for: .prompt, state: state)
            .onAppear {
                reload()
                hasOpenedOnce = true
                if let last = visibleLines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: visibleLines.count) { _, _ in
                if hasOpenedOnce, let last = visibleLines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: state.focusedSessionId) { _, _ in
                lastLoadedURL = ""  // force a reload even when the URL didn't change
                hasOpenedOnce = false
                showAllLines = false  // reset window for the new session
                reload()
                if let last = visibleLines.last {
                    // Defer to next runloop so the new content is laid out first.
                    DispatchQueue.main.async {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .onReceive(timer) { _ in reload() }
        .onChange(of: state.focusId) { _, _ in reload() }
        .onChange(of: state.focusTask?.history.count ?? 0) { _, _ in reload() }
        .onDisappear { stopWatching() }
    }

    // MARK: - Rendering

    @ViewBuilder
    private func chatBubble(_ line: ChatLine) -> some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(line.content)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#F1F2F4"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(line.content)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#D5D7DB"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .thinking:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#9A7BC8"))
                Text(line.content)
                    .font(.system(size: 11).italic())
                    .foregroundColor(Color(hex: "#9A7BC8"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .toolCall:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#5F8AFA"))
                Text(line.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#7B8089"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .system:
            Text(line.content)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#5C6370"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Collapsible row for thinking / tool-call lines (cc-switch inspired).
    /// Default collapsed: glyph + one-line preview, tappable to expand.
    /// User / assistant / system keep their existing rendering through
    /// ChatBubble.
    @ViewBuilder
    private func detailRow(_ line: ChatLine) -> some View {
        let isExpanded = expandedDetailIds.contains(line.id)
        Button {
            if isExpanded { expandedDetailIds.remove(line.id) }
            else { expandedDetailIds.insert(line.id) }
        } label: {
            switch line.role {
            case .thinking:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#9A7BC8"))
                    Text(line.content)
                        .font(.system(size: 11).italic())
                        .foregroundColor(Color(hex: "#9A7BC8"))
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .toolCall:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#5F8AFA"))
                    Text(line.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "#7B8089"))
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                // system and any future roles — plain dim text, no collapse
                Text(line.content)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#5C6370"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Tap to collapse" : "Tap to expand")
    }

    // MARK: - Loading

    private func reload() {
        // Resolve which Claude session to render. A tapped session pill sets
        // `focusedSessionId` so we read that session's JSONL even when it differs
        // from the focus task's last-known cwd.
        let target: (cwd: String, sid: String)? = {
            if let s = state.focusedClaudeSession {
                return (s.cwd, s.sessionId)
            }
            if let cwd = state.focusTask?.sessionCwd, let sid = state.focusTask?.sessionId {
                return (cwd, sid)
            }
            return nil
        }()
        let url: URL? = {
            if let t = target {
                let direct = SessionHistoryLoader.jsonlURL(cwd: t.cwd, sessionId: t.sid)
                if FileManager.default.fileExists(atPath: direct.path) { return direct }
                // cwd from the hook may be wrong (e.g. Orca sets cwd to the app dir).
                // Fall back to scanning all ~/.claude/projects/*/ for a matching JSONL.
                if let found = SessionHistoryLoader.locateSessionAcrossProjects(t.sid) { return found }
                return direct
            } else if let cwd = state.focusTask?.sessionCwd {
                return SessionHistoryLoader.mostRecentSessionURL(cwd: cwd)
            } else {
                return SessionHistoryLoader.mostRecentSessionAcrossProjects()
            }
        }()
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            let tried = url?.path ?? "<nil>"
            lines = []
            loadError = "no .jsonl found\ntried: \(tried)\nhome: \(NSHomeDirectory())"
            lastLoadedURL = "MISSING"
            stopWatching()
            return
        }
        // Size is our dirty check: same URL + same size = nothing changed
        // on disk. But in-memory history may have grown (user just sent a
        // message via sendMessage — that path appends to focusTask.history
        // before Claude Code has had a chance to write the JSONL), so we
        // always run the merge below; only the JSONL parse is skipped.
        let size: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let s = attrs[.size] as? UInt64 else { return 0 }
            return s
        }()
        let key = url.lastPathComponent
        let parsed: [ChatLine]
        if let cached = Self.parsedCache[key], cached.size == size {
            parsed = cached.lines
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                loadError = "could not read \(key)"
                return
            }
            parsed = parseJSONL(text)
            Self.parsedCache[key] = (size, parsed)
        }
        lines = mergeInMemory(parsed)
        lastLoadedURL = key
        lastLoadedSize = size
        loadError = nil
        startWatching(url: url)
    }

    /// Show the user's just-sent prompt instantly, before JSONL catches up.
    ///
    /// Why only the LAST user entry: `focusTask.history` is the global Claude
    /// integration task's history, not per-session. If multiple Claude Code
    /// sessions are active, blindly appending every entry would splice the
    /// wrong session's turns into this chat and clobber the JSONL's order.
    /// The freshest user entry is always the just-send one for the focused
    /// session (sendMessage appends it synchronously), so that's safe to
    /// surface; older user entries and assistant entries already arrived
    /// through JSONL in their correct position.
    private func mergeInMemory(_ jsonlLines: [ChatLine]) -> [ChatLine] {
        guard let memHistory = state.focusTask?.history,
              let lastUser = memHistory.last(where: { $0.role == .user })
        else { return jsonlLines }
        let key = Self.dedupKey(role: .user, content: lastUser.content)
        if jsonlLines.contains(where: { Self.dedupKey(role: $0.role, content: $0.content) == key }) {
            return jsonlLines
        }
        var out = jsonlLines
        out.append(ChatLine(role: .user, content: lastUser.content))
        return out
    }

    private static func dedupKey(role: ChatLine.Role, content: String) -> String {
        "\(role.rawValue)|\(content)"
    }

    /// Watch the JSONL file with a kernel-level dispatch source so the chat
    /// updates within milliseconds of Claude Code appending new tokens.
    /// Idempotent: already watching this exact path → no-op, so we don't
    /// cancel-and-reopen on every reload (which would risk missing events
    /// across the cycle). The cancel handler closes the fd — never close it
    /// anywhere else, mirroring HookServer's pattern.
    private func startWatching(url: URL) {
        if watchedPath == url.path, watchedFD >= 0, fileWatcher != nil { return }
        stopWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            // Defer to next runloop so the source is no longer "in handler"
            // by the time reload() → startWatching() cancels and recreates it.
            DispatchQueue.main.async { reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
        watchedFD = fd
        watchedPath = url.path
    }

    private func stopWatching() {
        fileWatcher?.cancel()  // cancel handler closes the fd
        fileWatcher = nil
        watchedFD = -1
        watchedPath = ""
    }

    /// Parse JSONL into structured chat lines. Skip metadata events
    /// (`last-prompt`, `mode`, `permission-mode`, `atis-latch`, `attachment`,
    /// `tool_use_result` echoes). Render user prompts, assistant text,
    /// thinking, and tool calls.
    private func parseJSONL(_ text: String) -> [ChatLine] {
        var out: [ChatLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let data = raw.data(using: .utf8) else { continue }
            guard let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let type = ev["type"] as? String,
                  let msg = ev["message"] as? [String: Any]
            else { continue }
            switch type {
            case "user":
                if let s = msg["content"] as? String, !s.isEmpty {
                    out.append(ChatLine(role: .user, content: s))
                }
            case "assistant":
                if let blocks = msg["content"] as? [[String: Any]] {
                    for b in blocks {
                        let bt = b["type"] as? String
                        if bt == "text", let t = b["text"] as? String, !t.isEmpty {
                            out.append(ChatLine(role: .assistant, content: t))
                        } else if bt == "thinking", let t = b["thinking"] as? String, !t.isEmpty {
                            out.append(ChatLine(role: .thinking, content: t))
                        } else if bt == "tool_use" {
                            let name = b["name"] as? String ?? "Tool"
                            let input = b["input"] as? [String: Any] ?? [:]
                            out.append(ChatLine(role: .toolCall, content: formatToolCall(name: name, input: input)))
                        }
                    }
                }
            default:
                break  // last-prompt, mode, permission-mode, atis-latch, attachment, etc.
            }
        }
        // Keep only the last 300 lines to avoid unbounded growth.
        return Array(out.suffix(300))
    }

    private func formatToolCall(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "$ \(cmd)"
        case "Read":
            return "read \((input["file_path"] as? String) ?? "")"
        case "Edit", "MultiEdit", "Write":
            return "\(name.lowercased()) \((input["file_path"] as? String) ?? "")"
        case "Glob":
            return "glob \((input["pattern"] as? String) ?? "")"
        case "Grep":
            let pattern = (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String) ?? ""
            return path.isEmpty ? "grep \(pattern)" : "grep \(pattern) in \(path)"
        case "WebFetch":
            return "fetch \((input["url"] as? String) ?? "")"
        case "TodoWrite":
            return "update todo list"
        case "Task":
            let desc = (input["description"] as? String) ?? ""
            return "task\(desc.isEmpty ? "" : ": \(desc)")"
        case "AskUserQuestion":
            return "ask user"
        default:
            return name
        }
    }
}

struct ChatLine: Identifiable {
    let id = UUID()
    let role: Role
    let content: String

    enum Role: String { case user, assistant, thinking, toolCall, system }
}
