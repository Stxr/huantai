import HuantaiCore
import XCTest
@testable import HuantaiApp

final class SessionSearchTests: XCTestCase {
    @MainActor
    func testSearchIgnoresDatesAndClearingRestoresSavedRange() throws {
        let suite = "huantai.search." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startServices: false, preferences: preferences)
        model.setFavoritesOnly(false)
        model.setSessionRecency(.day)
        model.snapshot.sessions = [
            SessionRecord(id: "old", title: "needle", cwd: "/", source: "Codex", machine: "local", lastAIReplyAt: .distantPast),
            SessionRecord(id: "missing-date", title: "needle", cwd: "/", source: "Codex", machine: "local"),
            SessionRecord(id: "recent", title: "other", cwd: "/", source: "Codex", machine: "local", lastAIReplyAt: .now),
        ]
        XCTAssertEqual(model.visibleSessions.map(\.id), ["recent"])
        model.sessionQuery = "needle"
        XCTAssertEqual(Set(model.visibleSessions.map(\.id)), ["old", "missing-date"])
        XCTAssertEqual(model.sessionRecency, .day)
        model.sessionQuery = "  "
        XCTAssertEqual(model.visibleSessions.map(\.id), ["recent"])
        XCTAssertEqual(preferences.string(forKey: "sessionRecency"), "day")
    }

    @MainActor
    func testBodyOnlyMatchAppearsInModelWithoutReplyDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "huantai.search.body." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let home = root.appendingPathComponent("dsh")
        let directory = home.appendingPathComponent("sessions/project/example")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = #"{"type":"session","version":0,"id":"example","cwd":"/fixture"}"# + "\n"
            + #"{"type":"user/message","data":{"content":"正文独有关键词"}}"#
        try Data(history.utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        let store = SessionStore(dataDirectory: root.appendingPathComponent("index"), deepSeekHarnessDirectory: home)
        try store.setSessionSource(.codex, enabled: false)
        let model = AppModel(startServices: false, preferences: preferences, store: store)
        model.snapshot = try store.refresh()
        model.setFavoritesOnly(true)
        model.snapshot.sessions[0].isCompleted = true
        model.setSessionRecency(.day)
        XCTAssertTrue(model.visibleSessions.isEmpty)
        model.sessionQuery = "正文独有关键词"
        for _ in 0..<300 {
            if !model.searchState.isSearching { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.searchState.isSearching)
        XCTAssertEqual(model.visibleSessions.map(\.id), ["dsh:example"])
        XCTAssertTrue(model.favoritesOnly)
        XCTAssertFalse(model.showsCompleted)
        model.sessionQuery = ""
        XCTAssertTrue(model.visibleSessions.isEmpty)
    }

    @MainActor
    func testObsoleteSearchCannotReplaceNewQueryResults() async {
        let firstStarted = expectation(description: "first started")
        let finished = expectation(description: "latest results")
        let releaseFirst = DispatchSemaphore(value: 0)
        var received: [SessionSearchState] = []
        let controller = SessionSearchController(search: { query, _, update in
            if query == "old" {
                firstStarted.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 3)
            }
            let result = SessionSearchResult(matchingIDs: [query])
            update(result)
            return result
        }, changed: { state in
            received.append(state)
            if state.query == "new" && !state.isSearching { finished.fulfill() }
        })
        controller.update(query: "old")
        await fulfillment(of: [firstStarted], timeout: 3)
        controller.update(query: "new")
        releaseFirst.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(received.contains { $0.result.matchingIDs.contains("old") })
        XCTAssertEqual(received.last?.result.matchingIDs, ["new"])
        controller.update(query: "")
        XCTAssertTrue(received.last?.result.matchingIDs.isEmpty == true)
        XCTAssertFalse(received.last?.isSearching == true)
    }
}
