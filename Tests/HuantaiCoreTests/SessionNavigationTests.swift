import HuantaiCore
import XCTest

final class SessionNavigationTests: XCTestCase {
    private let ordered = (1...7).map { "session-\($0)" }

    func testSeventhToFirstThenBackAndForwardUsesHistoryRatherThanSortOrder() throws {
        var navigation = SessionNavigation()
        navigation.didOpen("session-7")
        let first = try XCTUnwrap(
            navigation.target(for: .first, orderedIDs: ordered, availableIDs: Set(ordered)))
        XCTAssertEqual(first, "session-1")
        navigation.didOpen(first, action: .first)
        let back = try XCTUnwrap(
            navigation.target(for: .back, orderedIDs: ordered, availableIDs: Set(ordered)))
        XCTAssertEqual(back, "session-7")
        navigation.didOpen(back, action: .back)
        XCTAssertEqual(
            navigation.target(for: .forward, orderedIDs: ordered, availableIDs: Set(ordered)), "session-1")
    }

    func testNewNavigationAfterBackDiscardsForwardBranchAndRepeatedOpenDoesNotDuplicate() {
        var navigation = SessionNavigation()
        navigation.didOpen("session-1")
        XCTAssertEqual(
            navigation.target(for: .next, orderedIDs: ordered, availableIDs: Set(ordered)), "session-2")
        navigation.didOpen("session-2")
        navigation.didOpen("session-3")
        navigation.didOpen("session-2", action: .back)
        navigation.didOpen("session-2")
        XCTAssertEqual(
            navigation.target(for: .forward, orderedIDs: ordered, availableIDs: Set(ordered)), "session-3")
        navigation.didOpen("session-7")
        XCTAssertEqual(
            navigation.target(for: .previous, orderedIDs: ordered, availableIDs: Set(ordered)), "session-6")
        XCTAssertNil(navigation.target(for: .forward, orderedIDs: ordered, availableIDs: Set(ordered)))
        XCTAssertEqual(
            navigation.target(for: .back, orderedIDs: ordered, availableIDs: Set(ordered)), "session-2")
    }

    func testHistorySurvivesReorderingAndSkipsDeletedSessions() {
        var navigation = SessionNavigation()
        for id in ["session-1", "session-2", "session-7"] { navigation.didOpen(id) }
        XCTAssertEqual(
            navigation.target(
                for: .back, orderedIDs: ["session-7"], availableIDs: ["session-1", "session-7"]), "session-1")
        navigation.didOpen("session-1", action: .back)
        XCTAssertEqual(
            navigation.target(
                for: .forward, orderedIDs: Array(ordered.reversed()),
                availableIDs: ["session-1", "session-7"]), "session-7")
        XCTAssertEqual(
            navigation.target(
                for: .next, orderedIDs: ["session-1", "session-7"], availableIDs: Set(ordered)), "session-7")
    }

    func testEmptyListsAndSortedBoundariesDoNotWrap() {
        var navigation = SessionNavigation()
        XCTAssertNil(navigation.target(for: .next, orderedIDs: [], availableIDs: []))
        XCTAssertEqual(
            navigation.target(for: .next, orderedIDs: ordered, availableIDs: Set(ordered)), "session-1")
        navigation.didOpen("session-1")
        XCTAssertNil(navigation.target(for: .previous, orderedIDs: ordered, availableIDs: Set(ordered)))
        XCTAssertNil(navigation.target(for: .back, orderedIDs: ordered, availableIDs: Set(ordered)))
        navigation.didOpen("session-7")
        XCTAssertNil(navigation.target(for: .next, orderedIDs: ordered, availableIDs: Set(ordered)))
    }
}
