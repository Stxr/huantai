import XCTest

@testable import HuantaiCore

final class VisibleReplyTextTests: XCTestCase {
    func testSilentControlsAndCompleteCitationSuffix() {
        let citation =
            "<oai-mem-citation>\n<citation_entries>source</citation_entries>\n<rollout_ids>id</rollout_ids>\n</oai-mem-citation>"
        for text in [
            "BOTMUX_NOTHING_TO_SEND", " BOTMUX_NO_REPLY ",
            "BOTMUX_NOTHING_TO_SEND\n\nBOTMUX_NO_REPLY", "BOTMUX_NOTHING_TO_SEND\n" + citation,
        ] {
            XCTAssertTrue(VisibleReplyText.isSilent(text), text)
        }
        for text in [
            "", "普通回答", "解释 BOTMUX_NOTHING_TO_SEND", "普通回答\nBOTMUX_NOTHING_TO_SEND",
            "BOTMUX_NOTHING_TO_SEND\n<oai-mem-citation>unfinished", "BOTMUX_NOTHING_TO_SEND " + citation,
            "BOTMUX_NOTHING_TO_SEND\n" + citation + "\n后续正文",
        ] {
            XCTAssertFalse(VisibleReplyText.isSilent(text), text)
        }
    }
}
