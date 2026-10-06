import AppKit
import HuantaiCore
import XCTest

@testable import HuantaiApp

final class SessionOpeningTests: XCTestCase {
    @MainActor
    func testRapidSeventhFirstBackRequestsResolveAgainstCompletedOpens() async throws {
        let name = "huantai.navigation.fixture." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        var opened: [String] = []
        let complete = expectation(description: "three sequential source opens")
        complete.expectedFulfillmentCount = 3
        let model = AppModel(
            startServices: false, preferences: preferences,
            openSource: { url, completion in
                opened.append(String(url.path.dropFirst()))
                completion(nil)
                complete.fulfill()
            })
        model.setFavoritesOnly(false)
        model.snapshot.sessions = fixtures()
        let first = model.snapshot.sessions[0].id
        let seventh = model.snapshot.sessions[6].id
        model.openSession(model.snapshot.sessions[6])
        model.navigate(.first)
        model.navigate(.back)
        await fulfillment(of: [complete], timeout: 2)
        await drainMainQueue()
        XCTAssertEqual(opened, [seventh, first, seventh])
        XCTAssertEqual(model.navigation.currentID, seventh)
    }

    @MainActor
    func testFailedOpenLeavesCurrentAndHistoryUnchangedAndFilteredOrderIsUsed() async throws {
        let name = "huantai.navigation.fixture." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        var opened: [String] = []
        var fail = false
        let model = AppModel(
            startServices: false, preferences: preferences,
            openSource: { url, completion in
                opened.append(String(url.path.dropFirst()))
                completion(fail ? ShortcutError.message("合成打开失败") : nil)
            })
        model.snapshot.sessions = fixtures()
        model.setFavoritesOnly(true)
        model.snapshot.sessions[3].isFavorite = true
        model.navigate(.first)
        await drainMainQueue()
        let selected = model.snapshot.sessions[3].id
        XCTAssertEqual(opened, [selected])
        XCTAssertEqual(model.navigation.currentID, selected)
        fail = true
        model.setFavoritesOnly(false)
        model.navigate(.first)
        await drainMainQueue()
        XCTAssertEqual(model.navigation.currentID, selected)
        XCTAssertEqual(model.notice, "合成打开失败")
        XCTAssertNil(
            model.navigation.target(
                for: .back, orderedIDs: [], availableIDs: Set(model.snapshot.sessions.map(\.id))))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func fixtures() -> [SessionRecord] {
        (1...7).map { index in
            let id = "01234567-89ab-cdef-0123-456789abcde\(index)"
            return SessionRecord(
                id: id, title: "合成会话 \(index)", cwd: "/fixture", source: "Codex", machine: "本机",
                lastAIReplyAt: Date(timeIntervalSince1970: Double(100 - index)),
                openURL: SourceOpening.codexURL(sessionID: id))
        }
    }
}
