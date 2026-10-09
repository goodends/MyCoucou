import SwiftUI

/// Replaces PromptView. Shows the raw JSONL of the active Claude Code session
/// as monospaced text, refreshing every 2 s. No hooks, no events, no
/// Equatable gymnastics — just the file on disk, line by line.
///
/// Lines are coloured by JSON event type so the user can spot prompts,
/// thinking, tool calls and responses at a glance.
struct ChatSessionView: View {
    @ObservedObject var state: AppState
    @State private var lines: [String] = []
    @State private var lastLoadedURL: String = ""

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // DEBUG banner — proves the view is rendering and shows what's loaded
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("[ChatSessionView] file=\(lastLoadedURL.isEmpty ? "—" : lastLoadedURL) lines=\(lines.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Header: which file we're showing + line count
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: state.focusTask?.color ?? "#7B8089"))
                    .frame(width: 6, height: 6)
                Text(headerLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: "#7B8089"))
                Spacer()
                Text("\(lines.count) lines")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#5C6370"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider().opacity(0.3)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(colorFor(line: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: lines.count) { _, newCount in
                    if newCount > 0 {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
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
        if let task = state.focusTask {
            if task.id == "integration_claude" {
                return ClaudeHost.pillName(hostApp: task.hostApp)
            }
            return task.name
        }
        return "no agent focused"
    }

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
            lines = ["(no .jsonl session file found)"]
            lines.append("(tried: \(tried))")
            lines.append("(home=\(NSHomeDirectory()))")
            lastLoadedURL = "MISSING"
            return
        }
        // Avoid re-parsing if the file hasn't grown.
        if url.lastPathComponent == lastLoadedURL { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Cap at the last 800 lines so the view doesn't grow unbounded over a
        // long session. ScrollView/LazyVStack handle the rest.
        lines = Array(allLines.suffix(800))
        lastLoadedURL = url.lastPathComponent
    }

    /// Colour-code by JSON event type so the user can scan the stream.
    private func colorFor(line: String) -> Color {
        if line.contains("\"type\":\"user\"")        { return Color(hex: "#F4B400") }   // user prompt
        if line.contains("\"type\":\"assistant\"")  { return Color(hex: "#E0E5EA") }   // assistant text
        if line.contains("\"type\":\"system\"")     { return Color(hex: "#6B7079") }   // system
        if line.contains("\"type\":\"attachment\"") { return Color(hex: "#5C6370") }   // hook attachment
        if line.contains("\"type\":\"last-prompt\"") || line.contains("\"type\":\"mode\"") || line.contains("\"type\":\"permission-mode\"") {
            return Color(hex: "#5C6370")                                                  // metadata
        }
        if line.contains("\"thinking\"")            { return Color(hex: "#9A7BC8") }   // thinking
        if line.contains("\"tool_use\"")            { return Color(hex: "#5F8AFA") }   // tool call
        if line.contains("\"tool_use_result\"")     { return Color(hex: "#22C55E") }   // tool result
        return Color(hex: "#7B8089")                                                     // unknown
    }
}
