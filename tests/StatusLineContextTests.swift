import Foundation

/// The statusline payload the wrapper drops on disk. Only the fields
/// `StatusLineReader` reads are modelled; the real payload carries cost,
/// rate_limits and more that nothing reads yet.
private func payload(usedPercentage: Any?, windowSize: Int) -> String {
    let pct = usedPercentage.map { "\($0)" } ?? "null"
    return """
    {"session_id":"t1","model":{"id":"x"},"context_window":\
    {"context_window_size":\(windowSize),"used_percentage":\(pct)}}
    """
}

@main
enum StatusLineContextTests {
    static func main() {
        let dir = StatusLineReader.payloadDir!
        let sid = "test-session-\(UUID().uuidString)"
        let file = StatusLineReader.payloadURL(sessionId: sid)!
        defer { try? FileManager.default.removeItem(at: file) }

        func write(_ json: String) {
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try! json.write(to: file, atomically: true, encoding: .utf8)
        }

        // The normal case: a session a few percent in.
        write(payload(usedPercentage: 8, windowSize: 200_000))
        var cw = StatusLineReader.contextWindow(sessionId: sid)!
        precondition(abs(cw.usedFraction - 0.08) < 1e-9, "8% should read as 0.08, got \(cw.usedFraction)")
        precondition(cw.windowSize == 200_000)

        // A 1M session — the window comes from the payload, never from the name.
        write(payload(usedPercentage: 42, windowSize: 1_000_000))
        cw = StatusLineReader.contextWindow(sessionId: sid)!
        precondition(cw.windowSize == 1_000_000, "must not assume 200k, got \(cw.windowSize)")
        precondition(abs(cw.usedFraction - 0.42) < 1e-9)

        // used_percentage is null before the first API call of a session, and
        // again right after /compact. No data is the correct answer, not zero.
        write(payload(usedPercentage: nil, windowSize: 1_000_000))
        precondition(StatusLineReader.contextWindow(sessionId: sid) == nil,
                     "null used_percentage must read as no usage, not 0%")

        // A full context is still a full bar, not one that overflows the track.
        write(payload(usedPercentage: 100, windowSize: 200_000))
        precondition(StatusLineReader.contextWindow(sessionId: sid)!.usedFraction == 1.0)

        // Out-of-range values are clamped rather than rendered off the end.
        write(payload(usedPercentage: 140, windowSize: 200_000))
        precondition(StatusLineReader.contextWindow(sessionId: sid)!.usedFraction == 1.0)

        // A session that never went through the wrapper.
        precondition(StatusLineReader.contextWindow(sessionId: "no-such-session") == nil)

        // A payload with no context_window at all (older Claude Code).
        try! "{\"session_id\":\"t1\"}".write(to: file, atomically: true, encoding: .utf8)
        precondition(StatusLineReader.contextWindow(sessionId: sid) == nil)

        // Corrupt JSON must not take the caller down — it happens whenever the
        // wrapper is killed mid-write.
        try! "{\"context_window\":{\"used_p".write(to: file, atomically: true, encoding: .utf8)
        precondition(StatusLineReader.contextWindow(sessionId: sid) == nil)

        // A zero window would divide by zero; report no usage instead.
        write(payload(usedPercentage: 5, windowSize: 0))
        precondition(StatusLineReader.contextWindow(sessionId: sid) == nil)

        // The session id comes from a hook payload and becomes a file name, so
        // anything that could walk out of the payload directory is rejected.
        for hostile in ["../../.ssh/authorized_keys", "..", ".", "a/b", ""] {
            precondition(StatusLineReader.payloadURL(sessionId: hostile) == nil,
                         "must not build a path for \(hostile.debugDescription)")
        }

        print("StatusLineContextTests OK")
    }
}