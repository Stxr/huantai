import Foundation

public enum SessionNavigationAction: String, Codable, CaseIterable, Sendable {
    case previous, next, first, back, forward
}

/// Successful opens form a bounded, in-memory IDE-style history. Sorting and history are independent.
public struct SessionNavigation: Equatable, Sendable {
    public private(set) var currentID: String?
    private var failedTraversalID: String?
    private var history: [String] = []
    private var cursor = -1

    public init() {}

    public func target(
        for action: SessionNavigationAction, orderedIDs: [String], availableIDs: Set<String>
    ) -> String? {
        switch action {
        case .first: return orderedIDs.first
        case .previous, .next:
            guard let anchor = failedTraversalID ?? currentID,
                let index = orderedIDs.firstIndex(of: anchor)
            else {
                return orderedIDs.first
            }
            let indexAfterMove = index + (action == .previous ? -1 : 1)
            return orderedIDs.indices.contains(indexAfterMove) ? orderedIDs[indexAfterMove] : nil
        case .back, .forward:
            return historyIndex(for: action, availableIDs: availableIDs).map { history[$0] }
        }
    }

    /// Keep successful history/currentID intact, but allow ordered navigation past a failed open.
    public mutating func didFailToOpen(_ id: String, action: SessionNavigationAction? = nil) {
        guard action != .back, action != .forward else { return }
        failedTraversalID = id
    }

    public mutating func didOpen(_ id: String, action: SessionNavigationAction? = nil) {
        failedTraversalID = nil
        if let action, action == .back || action == .forward,
            let index = historyIndex(for: action, availableIDs: [id]), history[index] == id
        {
            cursor = index
            currentID = id
            return
        }
        guard currentID != id else { return }
        if cursor + 1 < history.count { history.removeSubrange((cursor + 1)..<history.count) }
        history.append(id)
        if history.count > 256 { history.removeFirst(history.count - 256) }
        cursor = history.count - 1
        currentID = id
    }

    private func historyIndex(for action: SessionNavigationAction, availableIDs: Set<String>) -> Int? {
        guard history.indices.contains(cursor) else { return nil }
        var index = cursor + (action == .back ? -1 : 1)
        while history.indices.contains(index) {
            if availableIDs.contains(history[index]) { return index }
            index += action == .back ? -1 : 1
        }
        return nil
    }
}
