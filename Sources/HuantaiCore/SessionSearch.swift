import Foundation

public struct SessionSearchResult: Sendable {
    public var matchingIDs: Set<String> = []
    public var warnings: [String] = []
    public init(matchingIDs: Set<String> = [], warnings: [String] = []) {
        self.matchingIDs = matchingIDs
        self.warnings = warnings
    }

    mutating func merge(_ other: SessionSearchResult) {
        matchingIDs.formUnion(other.matchingIDs)
        warnings += other.warnings
    }
}

extension SessionStore {
    /// Search complete histories on demand. Only matching IDs leave this operation;
    /// conversation bodies are neither added to index.json nor returned over SSH.
    public func search(
        query: String, isCancelled: @escaping () -> Bool = { false },
        update: (SessionSearchResult) -> Void = { _ in }
    ) -> SessionSearchResult {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return SessionSearchResult() }
        var result = SessionSearchResult()
        do {
            let configuration = try configuration()
            if configuration.codexEnabled {
                result.merge(searchLocalCodex(query: term, configuration: configuration, isCancelled: isCancelled))
                update(result)
            }
            if configuration.deepSeekHarnessEnabled && !isCancelled() {
                result.merge(searchLocalHarness(query: term, configuration: configuration, isCancelled: isCancelled))
                update(result)
            }
            for target in configuration.remoteTargets {
                if isCancelled() { return result }
                do {
                    let found = try RemoteCodexReader.search(target, query: term, isCancelled: isCancelled)
                    result.merge(found)
                } catch {
                    if !isCancelled() { result.warnings.append("\(target.name) 正文搜索失败：\(error.localizedDescription)") }
                }
                update(result)
            }
        } catch { result.warnings.append(error.localizedDescription) }
        return result
    }

    private func searchLocalCodex(
        query: String, configuration: StoreConfiguration, isCancelled: () -> Bool
    ) -> SessionSearchResult {
        var result = SessionSearchResult()
        do {
            let files = try localSearchFiles(configuration: configuration)
            var unreadable = 0
            for (id, url) in files {
                if isCancelled() { return result }
                guard let url else { unreadable += 1; continue }
                do {
                    if try SessionMessageSearch.contains(query, in: url, isCancelled: isCancelled) {
                        result.matchingIDs.insert(id)
                    }
                } catch { unreadable += 1 }
            }
            if unreadable > 0 { result.warnings.append("本机 \(unreadable) 个会话正文不可读") }
        } catch { result.warnings.append("本机 Codex 正文搜索失败：\(error.localizedDescription)") }
        return result
    }

    private func searchLocalHarness(
        query: String, configuration: StoreConfiguration, isCancelled: () -> Bool
    ) -> SessionSearchResult {
        let root = configuration.deepSeekHarnessHome.map { URL(fileURLWithPath: $0) }
            ?? deepSeekHarnessDirectory
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions").path) else {
            return SessionSearchResult()
        }
        do {
            return try DeepSeekHarnessScanner().search(query: query, home: root, isCancelled: isCancelled)
        } catch { return SessionSearchResult(warnings: ["DeepSeek Harness 正文搜索失败：\(error.localizedDescription)"]) }
    }

}
