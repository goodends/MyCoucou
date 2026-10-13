import Foundation

/// `StatusLineInstaller` rewrites one JSON string in a file that can hold API
/// keys and a dozen hooks. These pin the two things that would go wrong: a
/// command containing escaped quotes and backslashes (every `bash -c '…'`
/// statusline has those), and a replacement that must not reorder or reshape
/// anything else in the file.
@main
enum StatusLineInstallerTests {
    static func main() {
        // A real-world statusline: nested quotes, backslashes, single quotes.
        //
        // A raw literal on purpose. Written as a normal Swift string, `\"`
        // would collapse to a bare `"` and produce JSON the parser rejects —
        // so the fixture has to carry the two characters `\` and `"` to match
        // what an actual settings.json holds.
        let tricky = #"bash -c 'd=$(ls -d \"${X_DIR}\"/p/*/ | awk -F/ '\''{ print $1 }'\''); exec node \"$d/i.js\"'\''"#
        let original = """
        {
          "env": { "TOKEN": "sk-abc\\"def" },
          "hooks": { "Stop": [ { "hooks": [ { "command": "\\"a b\\"" } ] } ] },
          "includeCoAuthoredBy": false,
          "statusLine": {
            "type": "command",
            "command": "\(tricky)"
          },
          "model": "opus"
        }
        """

        let patched = patch(original, to: "/tmp/wrapper.sh")
        let out = parse(patched, "first")

        // The point of the rewrite: the new command took.
        let statusLine = out["statusLine"] as? [String: Any] ?? [:]
        precondition(statusLine["command"] as? String == "/tmp/wrapper.sh",
                     "replacement failed, got \(statusLine["command"] as? String ?? "nil")")
        precondition(statusLine["type"] as? String == "command")

        // Everything else survived. A re-serialise would reorder these keys and
        // re-escape the token; both are real failures, because this is the
        // user's settings file and the whole point is a one-line diff.
        precondition(out["model"] as? String == "opus")
        precondition(out["includeCoAuthoredBy"] as? Bool == false)
        precondition((out["env"] as? [String: Any])?["TOKEN"] as? String == "sk-abc\"def")
        let hooks = out["hooks"] as? [String: Any] ?? [:]
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        let inner = (stop.first?["hooks"] as? [[String: Any]]) ?? []
        precondition(inner.first?["command"] as? String == "\"a b\"",
                     "an unrelated hook command was rewritten")

        // The path contains a space, so what lands in settings.json is a
        // *shell-quoted* command: the quotes are part of the value, escaped
        // once by the JSON encoder on the way in. The installer stores the
        // command it is handed verbatim — adding the shell quoting is
        // `StatusLineReader.wrapperCommand`'s job, and doing it in both places
        // is how a path ends up doubly quoted.
        let quoted = "\"/Users/x/Library/Application Support/NotchBuddy/statusline-hook.sh\""
        let withSpace = parse(patch(original, to: quoted), "spaced path")
        precondition((withSpace["statusLine"] as? [String: Any])?["command"] as? String == quoted,
                     "a command containing quotes did not survive the round trip")

        // A file with no statusLine is refused, not turned into one.
        precondition(patchOrNil("{\"model\":\"opus\"}") == nil,
                     "must not invent a statusLine")

        // So is one whose statusLine we cannot match.
        precondition(patchOrNil("{\"statusLine\": {\"type\":\"command\"}}") == nil,
                     "statusLine without a command must not be rewritten")

        // Bytes that are not UTF-8 are not something to guess at.
        precondition(patchOrNilData(Data([0xFF, 0xFE, 0x00, 0x01])) == nil)

        print("StatusLineInstallerTests OK")
    }

    /// Parses and reports instead of trapping: a `try!` here would fail with
    /// no message once the file is compiled with optimisations on.
    private static func parse(_ data: Data, _ what: String) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("✗ \(what) did not produce a JSON object:")
            print(String(data: data, encoding: .utf8) ?? "<not UTF-8>")
            exit(1)
        }
        return object
    }

    private static func patch(_ json: String, to command: String) -> Data {
        let result = patchOrNil(json, command)
        precondition(result != nil, "patch failed for \(command)")
        return result!
    }

    private static func patchOrNil(_ json: String, _ command: String = "/tmp/wrapper.sh") -> Data? {
        patchOrNilData(json.data(using: .utf8)!, command)
    }

    private static func patchOrNilData(_ data: Data, _ command: String = "/tmp/wrapper.sh") -> Data? {
        StatusLineInstaller.replacingStatusLineCommand(in: data, with: command)
    }
}