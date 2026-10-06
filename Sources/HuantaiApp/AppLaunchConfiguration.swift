import Foundation
import HuantaiCore

enum AppLaunchConfiguration {
    // macOS login-item launches have no run-demo.sh environment. Retain the
    // configured directories so login and manual launches share the same data.
    static func store(
        preferences: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SessionStore {
        let testing = environment["HUANTAI_TEST_MODE"] == "1"
        func directory(_ key: String) -> URL? {
            let preferenceKey = "launchDirectory.\(key)"
            if let path = environment[key], !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                if !testing { preferences.set(url.path, forKey: preferenceKey) }
                return url
            }
            guard !testing, let path = preferences.string(forKey: preferenceKey), path.hasPrefix("/")
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let dataDirectory = directory("HUANTAI_HOME")
        let isolatedDSH =
            testing
            ? (dataDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent(
                "huantai-test-no-dsh") : nil
        return SessionStore(
            dataDirectory: dataDirectory, codexDirectory: directory("HUANTAI_CODEX_HOME"),
            botmuxDirectory: directory("HUANTAI_BOTMUX_HOME"),
            deepSeekHarnessDirectory: directory("HUANTAI_DSH_HOME") ?? isolatedDSH)
    }
}
