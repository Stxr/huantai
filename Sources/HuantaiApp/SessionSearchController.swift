import Foundation
import HuantaiCore

struct SessionSearchState {
    var query = ""
    var result = SessionSearchResult()
    var isSearching = false
}

/// Debounces typing and cancels obsolete reads. Results are delivered on the main queue.
final class SessionSearchController {
    typealias Search = (String, @escaping () -> Bool, (SessionSearchResult) -> Void) -> SessionSearchResult
    private let queue = DispatchQueue(label: "huantai.session-search", qos: .userInitiated)
    private let search: Search
    private let changed: (SessionSearchState) -> Void
    private var request: Request?

    init(search: @escaping Search, changed: @escaping (SessionSearchState) -> Void) {
        self.search = search
        self.changed = changed
    }

    func update(query: String) {
        request?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        changed(SessionSearchState(query: term, isSearching: !term.isEmpty))
        guard !term.isEmpty else { request = nil; return }
        let current = Request()
        request = current
        let search = search
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard !current.isCancelled else { return }
            let result = search(term, { current.isCancelled }) { result in
                self?.publish(result, query: term, request: current, isSearching: true)
            }
            self?.publish(result, query: term, request: current, isSearching: false)
        }
    }

    private func publish(_ result: SessionSearchResult, query: String, request: Request, isSearching: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard !request.isCancelled else { return }
            self?.changed(SessionSearchState(query: query, result: result, isSearching: isSearching))
        }
    }

    deinit { request?.cancel() }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    }
}
