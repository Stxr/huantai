import AppKit
import Foundation
import HuantaiCore
import SwiftUI

struct TaskHookSettingView: View {
    @ObservedObject var manager: TaskHookManager
    let sources: TaskHookSources

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                Button {
                    manager.setEnabled(!manager.enabled, sources: sources)
                } label: {
                    SettingsOptionRow(
                        symbol: "speaker.wave.2", title: "启用任务 Hook",
                        subtitle: manager.enabled ? "已开启任务状态音效" : "默认关闭，按需开启",
                        selected: manager.enabled)
                }
                .buttonStyle(.plain).disabled(manager.busy)
                .accessibilityLabel("启用任务状态音效")
                .accessibilityValue(manager.enabled ? "已开启" : "已关闭")
                .accessibilityAddTraits(manager.enabled ? .isSelected : [])
                Divider().padding(.horizontal, 14)
                Button {
                    manager.openSoundsFolder()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(Color.accentColor).frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("打开音效文件夹").font(.system(size: 12, weight: .medium))
                            Text("在文件夹里替换音乐，立即生效").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(
                            .secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.13)))
            if manager.enabled {
                Text("支持范围跟随“连接与数据”的勾选；取消勾选会移除对应 Hook。换台运行时播放音效。Codex 若提示需要信任，可在 /hooks 中审阅。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = manager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TaskHookSources: Equatable {
    var codexHome: URL?
    var deepSeekHarnessHome: URL?

    init(configuration: StoreConfiguration, codexHome: URL, deepSeekHarnessHome: URL) {
        self.codexHome =
            configuration.codexEnabled
            ? configuration.codexHome.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? codexHome : nil
        self.deepSeekHarnessHome =
            configuration.deepSeekHarnessEnabled
            ? configuration.deepSeekHarnessHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? deepSeekHarnessHome : nil
    }

    init(codexHome: URL? = nil, deepSeekHarnessHome: URL? = nil) {
        self.codexHome = codexHome
        self.deepSeekHarnessHome = deepSeekHarnessHome
    }
}

struct TaskHookConfiguration: Codable {
    var enabled = false
    // Installation history is retained for cleanup retries, separately from active sources.
    var installedHome: String?
    var installedDSHHome: String?
    var codexHome: String?
    var deepSeekHarnessHome: String?

    init(
        enabled: Bool = false, installedHome: String? = nil, installedDSHHome: String? = nil,
        codexHome: String? = nil, deepSeekHarnessHome: String? = nil
    ) {
        self.enabled = enabled
        self.installedHome = installedHome
        self.installedDSHHome = installedDSHHome
        self.codexHome = codexHome
        self.deepSeekHarnessHome = deepSeekHarnessHome
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, installedHome, installedDSHHome, codexHome, deepSeekHarnessHome
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        installedHome = try values.decodeIfPresent(String.self, forKey: .installedHome)
        installedDSHHome = try values.decodeIfPresent(String.self, forKey: .installedDSHHome)
        // Migrate the original Codex-only enabled setting without resetting custom sounds.
        codexHome =
            values.contains(.codexHome)
            ? try values.decodeIfPresent(String.self, forKey: .codexHome) : installedHome
        deepSeekHarnessHome = try values.decodeIfPresent(String.self, forKey: .deepSeekHarnessHome)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encodeIfPresent(installedHome, forKey: .installedHome)
        try values.encodeIfPresent(installedDSHHome, forKey: .installedDSHHome)
        try values.encode(codexHome, forKey: .codexHome)
        try values.encode(deepSeekHarnessHome, forKey: .deepSeekHarnessHome)
    }

    func accepts(_ source: SessionSource, home: String) -> Bool {
        let active = source == .codex ? codexHome : deepSeekHarnessHome
        return enabled
            && active.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                == URL(fileURLWithPath: home).standardizedFileURL.path
    }

    func permits(_ source: SessionSource) -> Bool {
        enabled && (source == .codex ? codexHome : deepSeekHarnessHome) != nil
    }
}

/// Owns only Huantai's command entries, preserving every other hook and config field.
struct CodexHookInstallation {
    let dataDirectory: URL
    var runtimeDirectory: URL { dataDirectory.appendingPathComponent("codex-hooks") }
    var configurationURL: URL { runtimeDirectory.appendingPathComponent("settings.json") }
    var soundsDirectory: URL { runtimeDirectory.appendingPathComponent("sounds") }
    var pendingDirectory: URL { runtimeDirectory.appendingPathComponent("pending") }
    var executableURL: URL { runtimeDirectory.appendingPathComponent("huantai-hook") }

    func configuration() -> TaskHookConfiguration {
        guard let data = try? Data(contentsOf: configurationURL),
            let value = try? JSONDecoder().decode(TaskHookConfiguration.self, from: data)
        else { return TaskHookConfiguration() }
        return value
    }

    func save(_ value: TaskHookConfiguration) throws {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: configurationURL, options: .atomic)
    }

    func prepareSounds(from defaults: URL) throws {
        if !FileManager.default.fileExists(atPath: soundsDirectory.path) {
            try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: defaults, to: soundsDirectory)
        }
        // Flatten the initial prototype without replacing a user's selected audio.
        for state in CodexTaskState.allCases {
            let old = soundsDirectory.appendingPathComponent(state.rawValue, isDirectory: true)
            guard FileManager.default.fileExists(atPath: old.path) else { continue }
            for file in audioFiles(in: old) {
                var destination = soundsDirectory.appendingPathComponent(
                    state.rawValue + "." + file.pathExtension)
                if sound(for: state) != nil {
                    destination = soundsDirectory.appendingPathComponent(
                        state.rawValue + "-previous-" + file.lastPathComponent)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        destination = soundsDirectory.appendingPathComponent(
                            state.rawValue + "-previous-" + UUID().uuidString + "." + file.pathExtension)
                    }
                }
                try FileManager.default.moveItem(at: file, to: destination)
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty) == true {
                try FileManager.default.removeItem(at: old)
            }
        }
        // README is app-owned guidance; sound files remain user-owned.
        let instructions = defaults.appendingPathComponent("README.txt")
        if FileManager.default.fileExists(atPath: instructions.path) {
            try Data(contentsOf: instructions).write(
                to: soundsDirectory.appendingPathComponent("README.txt"), options: .atomic)
        }
    }

    var command: String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return quote(executableURL.path) + " --huantai-codex-hook --hook-home " + quote(dataDirectory.path)
    }

    func install(in codexHome: URL, executable: URL) throws {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        // Stable executable path keeps hooks working after the App moves or closes.
        if executable.standardizedFileURL != executableURL.standardizedFileURL {
            try Data(contentsOf: executable).write(to: executableURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        }
        try editHooks(in: codexHome, enabled: true)
    }

    func remove(from codexHome: URL) throws { try editHooks(in: codexHome, enabled: false) }

    private func editHooks(in codexHome: URL, enabled: Bool) throws {
        let url = codexHome.appendingPathComponent("hooks.json")
        let existed = FileManager.default.fileExists(atPath: url.path)
        var document: [String: Any] = [:]
        if existed {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["hooks"] == nil || object["hooks"] is [String: Any]
            else { throw HookError.message("Codex hooks.json 格式不正确，原文件已保留。") }
            document = object
        } else if !enabled {
            return
        }
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        for event in ["UserPromptSubmit", "Stop", "Interrupt"] {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                throw HookError.message("Codex \(event) hook 格式不正确，原文件已保留。")
            }
            var groups: [[String: Any]] = []
            for var group in hooks[event] as? [[String: Any]] ?? [] {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw HookError.message("Codex hook 命令格式不正确，原文件已保留。")
                }
                let kept = handlers.filter { $0["command"] as? String != command }
                if kept.count == handlers.count {
                    groups.append(group)
                } else if !kept.isEmpty {
                    group["hooks"] = kept
                    groups.append(group)
                }
            }
            if enabled {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        // Preserve an existing empty document and any unrelated top-level metadata.
        if !enabled && hooks.isEmpty && document.keys.allSatisfy({ $0 == "hooks" }) {
            try FileManager.default.removeItem(at: url)
        } else {
            document["hooks"] = hooks
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
        }
    }

    private func audioFiles(in directory: URL) -> [URL] {
        let supported = ["wav", "mp3", "aiff", "aif", "m4a", "caf"]
        return
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]))?
            .filter {
                supported.contains($0.pathExtension.lowercased())
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    func sound(for state: CodexTaskState) -> URL? {
        audioFiles(in: soundsDirectory).first {
            $0.deletingPathExtension().lastPathComponent == state.rawValue
        }
    }

    /// Short-lived command hook: ignores prompts/replies and returns valid, non-blocking output.
    static func receive(arguments: [String], input: Data) {
        guard let index = arguments.firstIndex(of: "--hook-home"), index + 1 < arguments.count,
            let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
            let path = payload["transcript_path"] as? String
        else { return }
        let installation = Self(dataDirectory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        guard installation.configuration().permits(.codex) else { return }
        // Only the path is needed to discover a resumed transcript. No conversation content is saved.
        let signal: [String: Any] = ["transcript": path, "created": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: signal) {
            try? data.write(
                to: installation.pendingDirectory.appendingPathComponent(UUID().uuidString + ".json"),
                options: .atomic)
        }
    }
}

enum HookError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

extension CodexHookInstallation {
    /// Save source gates first: even an already loaded plugin stops emitting immediately.
    @discardableResult
    func synchronize(enabled: Bool, sources: TaskHookSources, executable: URL, plugin: URL) throws
        -> TaskHookConfiguration
    {
        var configuration = self.configuration()
        configuration.enabled = enabled
        configuration.codexHome = enabled ? sources.codexHome?.standardizedFileURL.path : nil
        configuration.deepSeekHarnessHome =
            enabled ? sources.deepSeekHarnessHome?.standardizedFileURL.path : nil
        try save(configuration)
        var errors: [String] = []
        do {
            if let old = configuration.installedHome, old != configuration.codexHome {
                try remove(from: URL(fileURLWithPath: old, isDirectory: true))
                configuration.installedHome = nil
            }
            if let root = configuration.codexHome {
                try install(in: URL(fileURLWithPath: root, isDirectory: true), executable: executable)
                configuration.installedHome = root
            }
        } catch { errors.append(error.localizedDescription) }
        let harness = DeepSeekHarnessHookInstallation(runtimeDirectory: runtimeDirectory)
        do {
            if let old = configuration.installedDSHHome, old != configuration.deepSeekHarnessHome {
                try harness.remove(
                    from: URL(fileURLWithPath: old, isDirectory: true), dataDirectory: dataDirectory)
                configuration.installedDSHHome = nil
            }
            if let root = configuration.deepSeekHarnessHome {
                try harness.install(
                    in: URL(fileURLWithPath: root, isDirectory: true), plugin: plugin,
                    dataDirectory: dataDirectory)
                configuration.installedDSHHome = root
            }
        } catch { errors.append(error.localizedDescription) }
        try save(configuration)
        if !errors.isEmpty { throw HookError.message(errors.joined(separator: "\n")) }
        return configuration
    }
}

final class TaskHookManager: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    let installation: CodexHookInstallation
    private let queue = DispatchQueue(label: "huantai.task-hooks", qos: .utility)
    private let audioQueue = DispatchQueue(label: "huantai.task-sounds", qos: .utility)
    private let playerLock = NSLock()
    private var player: Process?
    private var cancelledPlayers = Set<ObjectIdentifier>()
    private var playbackGeneration: [SessionSource: Int] = [:]
    private var playerSource: SessionSource?
    private var monitoredCodexHome: String?
    private var hasSynchronized = false
    private var pendingUpdates = 0
    private var timer: DispatchSourceTimer?
    private var monitor: CodexTaskMonitor?
    private var deliveredDSH = Set<String>()
    private var deliveredOrder: [String] = []
    private let servicesEnabled: Bool
    private var sources: TaskHookSources

    init(dataDirectory: URL, sources: TaskHookSources, startServices: Bool) {
        installation = CodexHookInstallation(dataDirectory: dataDirectory)
        let saved = installation.configuration()
        enabled = saved.enabled
        self.sources = sources
        servicesEnabled = startServices
        // Includes cleanup retries after a previously malformed external configuration.
        if startServices && (saved.enabled || saved.installedHome != nil || saved.installedDSHHome != nil) {
            synchronize(enabled: saved.enabled, sources: sources)
        }
    }

    private var defaultsURL: URL? {
        let native = Bundle.main.resourceURL?.appendingPathComponent("CodexSounds")
        if let native, FileManager.default.fileExists(atPath: native.path) { return native }
        return nil
    }

    func openSoundsFolder() {
        do {
            guard let defaultsURL else { throw HookError.message("找不到默认音效。") }
            try installation.prepareSounds(from: defaultsURL)
            if !NSWorkspace.shared.open(installation.soundsDirectory) {
                throw HookError.message("无法打开音效文件夹。")
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func setEnabled(_ value: Bool, sources: TaskHookSources) {
        guard !busy, value != enabled else { return }
        self.sources = sources
        synchronize(enabled: value, sources: sources)
    }

    /// Serialized updates are never dropped while an earlier installation is busy.
    func updateSources(_ sources: TaskHookSources) {
        guard self.sources != sources else { return }
        self.sources = sources
        guard enabled || busy else { return }
        // The queue reads the current persisted master switch, including a preceding toggle.
        synchronize(enabled: nil, sources: sources)
    }

    private func synchronize(enabled requested: Bool?, sources: TaskHookSources) {
        pendingUpdates += 1
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let old = self.installation.configuration()
            let value = requested ?? old.enabled
            let nextCodex = value ? sources.codexHome?.standardizedFileURL.path : nil
            let nextDSH = value ? sources.deepSeekHarnessHome?.standardizedFileURL.path : nil
            var changed = Set<SessionSource>()
            if old.codexHome != nextCodex || !value { changed.insert(.codex) }
            if old.deepSeekHarnessHome != nextDSH || !value { changed.insert(.deepSeekHarness) }
            self.stopMonitoring(changed: changed)
            if !self.hasSynchronized {
                self.drainSignals(discard: true)
                self.hasSynchronized = true
            } else if changed.contains(.deepSeekHarness) {
                self.discardHarnessSignals()
            }
            // Retain offsets for an unchanged Codex source while another source changes.
            if let root = nextCodex, self.monitoredCodexHome != root {
                self.monitor = CodexTaskMonitor(root: URL(fileURLWithPath: root, isDirectory: true))
                self.monitoredCodexHome = root
            }
            var failure: String?
            do {
                guard let executable = Bundle.main.executableURL,
                    let plugin = Bundle.main.resourceURL?.appendingPathComponent("HuantaiDSHHook.mjs")
                else { throw HookError.message("找不到任务 Hook。") }
                if value {
                    guard let defaults = self.defaultsURL else { throw HookError.message("找不到默认音效。") }
                    try self.installation.prepareSounds(from: defaults)
                }
                try self.installation.synchronize(
                    enabled: value, sources: sources,
                    executable: executable, plugin: plugin)
            } catch { failure = error.localizedDescription }
            let applied = self.installation.configuration()
            if applied.enabled && self.servicesEnabled { self.startMonitoring(configuration: applied) }
            DispatchQueue.main.async {
                self.enabled = applied.enabled
                self.pendingUpdates -= 1
                self.busy = self.pendingUpdates > 0
                self.errorMessage = failure
            }
        }
    }

    private func startMonitoring(configuration: TaskHookConfiguration) {
        if configuration.codexHome != configuration.installedHome {
            monitor = nil
            monitoredCodexHome = nil
        }
        // Preserve fresh events from sources that were unaffected by the selection change.
        drainSignals(discard: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.installation.configuration().enabled else { return }
            self.drainSignals(discard: false)
            for event in self.monitor?.poll() ?? [] { self.play(event.state, source: .codex) }
        }
        timer.resume()
        self.timer = timer
    }

    private func drainSignals(discard: Bool) {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: installation.pendingDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var signals: [[String: Any]] = []
        for url in urls where url.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: url) }
            guard !discard, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size <= 8192, let data = try? Data(contentsOf: url),
                let signal = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            signals.append(signal)
        }
        // Directory enumeration has no ordering guarantee; fast tasks must still start before ending.
        signals.sort {
            let left = $0["created"] as? Double ?? 0
            let right = $1["created"] as? Double ?? 0
            return left == right
                ? $0["state"] as? String == "started" && $1["state"] as? String != "started"
                : left < right
        }
        for signal in signals {
            guard let stamp = signal["created"] as? Double,
                stamp.isFinite, (0..<30).contains(Date().timeIntervalSince1970 - stamp)
            else { continue }
            if signal["source"] as? String == "deepSeekHarness" {
                guard let home = signal["home"] as? String,
                    self.installation.configuration().accepts(.deepSeekHarness, home: home),
                    let session = signal["session"] as? String, !session.isEmpty, session.count <= 128,
                    let turn = signal["turn"] as? Int, turn > 0,
                    let raw = signal["state"] as? String, let state = CodexTaskState(rawValue: raw)
                else { continue }
                let key =
                    home + ":" + session + ":" + String(turn) + ":"
                    + (state == .started ? "started" : "terminal")
                guard deliveredDSH.insert(key).inserted else { continue }
                deliveredOrder.append(key)
                if deliveredOrder.count > 2048 { deliveredDSH.remove(deliveredOrder.removeFirst()) }
                self.play(state, source: .deepSeekHarness)
            } else if let path = signal["transcript"] as? String {
                monitor?.includeTranscript(URL(fileURLWithPath: path))
            }
        }
    }

    private func discardHarnessSignals() {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: installation.pendingDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8192,
                let data = try? Data(contentsOf: file),
                let signal = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                signal["source"] as? String == "deepSeekHarness"
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func stopMonitoring(changed: Set<SessionSource>) {
        timer?.cancel()
        timer = nil
        if changed.contains(.codex) {
            monitor = nil
            monitoredCodexHome = nil
        }
        playerLock.lock()
        for source in changed { playbackGeneration[source, default: 0] += 1 }
        if let player, let source = playerSource, changed.contains(source), player.isRunning {
            cancelledPlayers.insert(ObjectIdentifier(player))
            player.terminate()
        }
        playerLock.unlock()
    }

    private func play(_ state: CodexTaskState, source: SessionSource) {
        let enqueuedAt = Date()
        playerLock.lock()
        let generation = playbackGeneration[source, default: 0]
        playerLock.unlock()
        audioQueue.async { [weak self] in
            guard let self, self.installation.configuration().permits(source),
                Date().timeIntervalSince(enqueuedAt) < 30, let sound = self.installation.sound(for: state)
            else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = [sound.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                self.playerLock.lock()
                guard self.playbackGeneration[source, default: 0] == generation,
                    self.installation.configuration().permits(source)
                else {
                    self.playerLock.unlock()
                    return
                }
                do {
                    try process.run()
                    self.player = process
                    self.playerSource = source
                    self.playerLock.unlock()
                } catch {
                    self.playerLock.unlock()
                    throw error
                }
                process.waitUntilExit()
                self.playerLock.lock()
                self.player = nil
                self.playerSource = nil
                let cancelled = self.cancelledPlayers.remove(ObjectIdentifier(process)) != nil
                self.playerLock.unlock()
                if !cancelled && process.terminationStatus != 0
                    && self.installation.configuration().permits(source)
                {
                    throw HookError.message("音效无法播放：\(sound.lastPathComponent)，请在音效文件夹替换文件。")
                }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }

    deinit {
        timer?.cancel()
        if player?.isRunning == true { player?.terminate() }
    }
}
