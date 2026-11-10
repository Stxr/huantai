import Foundation

/// Botmux may finish with a silent marker after sending the real answer through its CLI.
/// Recover the literal message only from a completed send with an acknowledged message ID.
enum BotmuxSentMessage {
    static func text(in payload: [String: Any]) -> String? {
        guard payload["type"] as? String == "item_completed",
            let item = payload["item"] as? [String: Any],
            item["type"] as? String == "CommandExecution",
            item["status"] as? String == "completed", item["exit_code"] as? Int == 0,
            let output = item["aggregated_output"] as? String, acknowledged(output),
            let command = item["command"] as? [String]
        else { return nil }
        if command.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "botmux",
            command.dropFirst().first == "send", let index = command.firstIndex(of: "--text"),
            command.indices.contains(index + 1) {
            return command[index + 1]
        }
        guard command.count == 3, ["bash", "zsh", "sh"].contains(URL(fileURLWithPath: command[0]).lastPathComponent),
            ["-c", "-lc"].contains(command[1]) else { return nil }
        return heredocBody(command[2])
    }

    private static func acknowledged(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            guard let data = String(line).data(using: .utf8),
                let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                result["success"] as? Bool == true,
                let id = result["messageId"] as? String else { return false }
            return id.hasPrefix("om_")
        }
    }

    private static func heredocBody(_ command: String) -> String? {
        let lines = command.components(separatedBy: "\n")
        guard let header = lines.first,
            header.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|`")) == nil,
            !header.contains("$("),
            header.range(of: #"^\s*(?:[^\s]+/)?botmux\s+send\b"#, options: .regularExpression) != nil,
            let expression = try? NSRegularExpression(pattern: #"<<\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1\s*$"#),
            let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
            let range = Range(match.range(at: 2), in: header)
        else { return nil }
        let delimiter = String(header[range])
        guard let end = lines.dropFirst().firstIndex(of: delimiter),
            lines.dropFirst(end + 1).allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return lines[1..<end].joined(separator: "\n")
    }
}
