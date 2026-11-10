import Foundation

/// Botmux control-only replies do not represent visible conversation activity.
enum VisibleReplyText {
    static func isSilent(_ text: String) -> Bool {
        var body = text
        // Ignore a complete trailing memory attribution envelope when identifying silence.
        // Inline mentions and incomplete envelopes remain ordinary answer text.
        if let range = body.range(of: "<oai-mem-citation>", options: .backwards),
            range.lowerBound == body.startIndex
                || ["\n", "\r"].contains(String(body[body.index(before: range.lowerBound)]))
        {
            let suffix = String(body[range.lowerBound...])
            let pattern =
                #"^<oai-mem-citation>\s*<citation_entries>(?:(?!</citation_entries>)[\s\S])*?</citation_entries>\s*<rollout_ids>(?:(?!</rollout_ids>)[\s\S])*?</rollout_ids>\s*</oai-mem-citation>\s*$"#
            if suffix.range(of: pattern, options: .regularExpression) != nil {
                body = String(body[..<range.lowerBound])
            }
        }
        let parts = body.split(whereSeparator: \.isWhitespace)
        return !parts.isEmpty
            && parts.allSatisfy {
                $0 == "BOTMUX_NOTHING_TO_SEND" || $0 == "BOTMUX_NO_REPLY"
            }
    }
}
