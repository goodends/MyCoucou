import SwiftUI

/// Replaces PromptView. Renders the active Claude Code session as a chat-bubble
/// stream parsed from the JSONL log on disk. Refreshes every 2 s so the view
/// tracks the running session in real time. No hooks, no events, no
/// Equatable gymnastics — just the file on disk.
struct ChatSessionView: View {
    @ObservedObject var state: AppState
    @State private var lines: [ChatLine] = []
    @State private var lastLoadedURL: String = ""
    @State private var loadError: String? = nil

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: state.focusTask?.color ?? "#7B8089"))
                    .frame(width: 6, height: 6)
                Text(headerLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: "#7B8089"))
                Spacer()
                Text(loadError == nil ? "\(lines.count) lines" : "err")
                    .font(.system(size: 10))
                    .foregroundColor(loadError == nil ? Color(hex: "#5C6370") : Color(hex: "#F4505E"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider().opacity(0.25)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if let err = loadError {
                            Text(err)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "#F4505E"))
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                        }
                        ForEach(lines) { line in
                            chatBubble(line)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(hex: "#0B0C0E"))
        .onAppear { reload() }
        .onReceive(timer) { _ in reload() }
        .onChange(of: state.focusId) { _, _ in reload() }
    }

    private var headerLabel: String {
        guard let task = state.focusTask else { return "no agent focused" }
        if task.id == "integration_claude" {
            return ClaudeHost.pillName(hostApp: task.hostApp)
        }
        return task.name
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

    // MARK: - Loading

    private func reload() {
        let url: URL? = {
            if let cwd = state.focusTask?.sessionCwd, let sid = state.focusTask?.sessionId {
                return SessionHistoryLoader.jsonlURL(cwd: cwd, sessionId: sid)
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
            return
        }
        // Skip if we're already showing this file. (Future: mtime-based dirty check.)
        if url.lastPathComponent == lastLoadedURL { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "could not read \(url.lastPathComponent)"
            return
        }
        lines = parseJSONL(text)
        lastLoadedURL = url.lastPathComponent
        loadError = nil
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
