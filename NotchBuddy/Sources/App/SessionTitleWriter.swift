import Foundation

/// Renames a Claude Code session the way its own `/rename` does.
///
/// The name lives in two places and Claude Code writes both of them:
///
/// - a `custom-title` record appended to the session's transcript
/// - a `custom-title.json` in a folder named after the session, beside the
///   transcript
///
/// `/resume` reads the transcript first and falls back to the sidecar, so
/// writing only one of them leaves the name half-set.
///
/// An empty name clears it, the way Claude Code does: the record still goes
/// into the transcript, and the sidecar goes away.
enum SessionTitleWriter {

    enum WriteError: Error {
        /// The session has no transcript, so the name has nowhere to go.
        case noTranscript
        /// The transcript could not be written to.
        case transcriptUnwritable(String)
    }

    /// Name a session. An empty name clears it.
    static func rename(sessionId: String, to title: String, transcript: URL) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record: [String: String] = [
            "type": "custom-title",
            "customTitle": name,
            "sessionId": sessionId,
        ]
        let line = try JSONSerialization.data(withJSONObject: record)
        try append(line, to: transcript)
        try writeSidecar(name, sessionId: sessionId, transcript: transcript)
    }

    /// Append one line to the transcript.
    ///
    /// The transcript is append-only and Claude Code holds it open, so the
    /// line goes in at the end and nothing already there is touched. The
    /// file may not end on a newline — Claude Code writes a partial record
    /// while a turn is running — and appending after one would glue the two
    /// together into a line that parses as neither.
    private static func append(_ line: Data, to url: URL) throws {
        // O_APPEND: the write lands at the end of the file even if Claude
        // Code appends to it between our read and our write.
        let fd = open(url.path, O_RDWR | O_APPEND)
        guard fd >= 0 else {
            throw WriteError.transcriptUnwritable("could not open \(url.lastPathComponent)")
        }
        defer { close(fd) }

        var payload = Data()
        let size = lseek(fd, 0, SEEK_END)
        if size > 0 {
            // The last byte tells us whether the file ends on a line. Read it
            // from a seek, not from the end: the read has to start there.
            _ = lseek(fd, size - 1, SEEK_SET)
            var last: UInt8 = 0
            let got = withUnsafeMutablePointer(to: &last) { read(fd, $0, 1) }
            if got == 1, last != 0x0A { payload.append(0x0A) }
        }
        payload.append(line)
        payload.append(0x0A)

        try payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = write(fd, base.advanced(by: written), buffer.count - written)
                guard n > 0 else {
                    throw WriteError.transcriptUnwritable("could not write the name")
                }
                written += n
            }
        }
    }

    /// The sidecar Claude Code keeps beside the transcript: a folder named
    /// after the session, holding the title as JSON.
    private static func sidecarURL(sessionId: String, transcript: URL) -> URL {
        transcript.deletingLastPathComponent()
            .appendingPathComponent(sessionId)
            .appendingPathComponent("custom-title.json")
    }

    /// Write the sidecar, or remove it when the name is empty — Claude Code
    /// deletes it rather than leaving an empty title behind.
    private static func writeSidecar(_ name: String, sessionId: String, transcript: URL) throws {
        let url = sidecarURL(sessionId: sessionId, transcript: transcript)
        guard !name.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: ["customTitle": name])
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
