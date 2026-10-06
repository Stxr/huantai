import Foundation

/// A marked, passive Cordis plugin insertion in DSH's machine-wide patch layer.
/// Other patches (including !!js expressions and comments) are preserved verbatim.
struct DeepSeekHarnessHookInstallation {
    let runtimeDirectory: URL
    var pluginURL: URL { runtimeDirectory.appendingPathComponent("huantai-dsh-hook.mjs") }
    private static let begin = "# BEGIN huantai-task-hook\n"
    private static let end = "# END huantai-task-hook\n"

    func install(in home: URL, plugin: URL, dataDirectory: URL) throws {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        if plugin.standardizedFileURL != pluginURL.standardizedFileURL {
            try Data(contentsOf: plugin).write(to: pluginURL, options: .atomic)
        }
        try edit(in: home, dataDirectory: dataDirectory, enabled: true)
    }

    func remove(from home: URL, dataDirectory: URL) throws {
        try edit(in: home, dataDirectory: dataDirectory, enabled: false)
    }

    private func edit(in home: URL, dataDirectory: URL, enabled: Bool) throws {
        let url = home.appendingPathComponent("cordis.patch.yml")
        let original =
            try FileManager.default.fileExists(atPath: url.path)
            ? String(contentsOf: url, encoding: .utf8) : nil
        let edited = try Self.content(
            original, enabled: enabled, plugin: pluginURL, dataDirectory: dataDirectory, home: home)
        guard edited != original else { return }
        if let edited {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data(edited.utf8).write(to: url, options: .atomic)
        } else if original != nil {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func content(
        _ original: String?, enabled: Bool, plugin: URL, dataDirectory: URL, home: URL,
        validate: (String) throws -> Void = validatePatch
    ) throws -> String? {
        var base = original ?? ""
        let starts = base.components(separatedBy: begin).count - 1
        let ends = base.components(separatedBy: end).count - 1
        guard starts == ends, starts <= 1 else {
            throw HookError.message("DeepSeek Harness Hook 标记不完整，原配置已保留。")
        }
        if let start = base.range(of: begin), let finish = base.range(of: end),
            finish.lowerBound > start.upperBound
        {
            let block = String(base[start.upperBound..<finish.lowerBound])
            // Verify ownership rather than remove a similarly named user plugin.
            guard let insertion = block.split(separator: "\n").first(where: { $0.hasPrefix("- insert: ") }),
                let entries = try? JSONSerialization.jsonObject(with: Data(insertion.dropFirst(10).utf8))
                    as? [[String: Any]], entries.count == 1,
                entries.first?["id"] as? String == "huantai-task-sounds",
                entries.first?["name"] as? String == plugin.path
            else {
                throw HookError.message("DeepSeek Harness Hook 路径已被修改，原配置已保留。")
            }
            var restored = ""
            if let line = block.split(separator: "\n").first(where: { $0.hasPrefix("# original-empty: ") }),
                let bytes = Data(base64Encoded: String(line.dropFirst(18))),
                let value = String(data: bytes, encoding: .utf8)
            {
                restored = value
            }
            var removalStart = start.lowerBound
            if block.split(separator: "\n").contains("# original-no-newline"),
                removalStart > base.startIndex, base[base.index(before: removalStart)] == "\n"
            {
                removalStart = base.index(before: removalStart)
            }
            base.replaceSubrange(removalStart..<finish.upperBound, with: restored)
        } else if starts != 0 {
            throw HookError.message("DeepSeek Harness Hook 标记顺序不正确，原配置已保留。")
        }
        if !enabled {
            return base.isEmpty ? nil : base
        }
        let entry: [String: Any] = [
            "id": "huantai-task-sounds", "name": plugin.path,
            "config": ["stateDirectory": dataDirectory.path, "harnessHome": home.standardizedFileURL.path],
        ]
        let json = String(
            decoding: try JSONSerialization.data(
                withJSONObject: [entry], options: [.sortedKeys, .withoutEscapingSlashes]),
            as: UTF8.self)
        var block = begin
        // DSH often initializes a patch file as []. Retain its bytes for exact removal.
        let meaningful = base.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if meaningful == "[]" {
            block += "# original-empty: " + Data(base.utf8).base64EncodedString() + "\n"
            base = ""
        } else if !meaningful.isEmpty {
            try validate(base)
            // Appending a block sequence to a flow-style list would change its meaning.
            guard meaningful.hasPrefix("-") else {
                throw HookError.message("DeepSeek Harness patch 请使用逐行列表格式，原配置已保留。")
            }
        }
        if !base.isEmpty && !base.hasSuffix("\n") {
            block += "# original-no-newline\n"
            base += "\n"
        }
        let result = base + block + "- insert: " + json + "\n" + end
        // Existing patches are validated with the same YAML dialect DSH uses before any write.
        if !meaningful.isEmpty && meaningful != "[]" { try validate(result) }
        return result
    }

    private static func validatePatch(_ text: String) throws {
        let fm = FileManager.default
        let applicationRoots = [
            "/Applications/DeepSeek Harness.app",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DeepSeek Harness.app").path,
        ]
        var runtimes = applicationRoots.map {
            (
                executable: $0 + "/Contents/MacOS/DeepSeek Harness",
                yaml: $0 + "/Contents/Resources/app.asar/dsh/node_modules/js-yaml", electron: true
            )
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            runtimes.append(
                (
                    prefix + "/bin/node", prefix + "/lib/node_modules/@deepseek-ai/dsh/node_modules/js-yaml",
                    false
                ))
        }
        let script = """
            const fs=require('node:fs'),yaml=require(process.argv[1]);
            const schema=yaml.JSON_SCHEMA.extend(new yaml.Type('tag:yaml.org,2002:js',
              {kind:'scalar',construct:data=>({__jsExpr:data})}));
            const value=yaml.load(fs.readFileSync(0,'utf8'),{schema});
            if(!Array.isArray(value)) throw Error('expected a patch list');
            """
        var available = false
        for runtime in runtimes where fm.isExecutableFile(atPath: runtime.executable) {
            // ASAR paths can only be read inside Electron, so use that runtime's filesystem.
            if !runtime.electron && !fm.fileExists(atPath: runtime.yaml) { continue }
            available = true
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtime.executable)
            process.arguments = ["-e", script, runtime.yaml]
            if runtime.electron {
                var environment = ProcessInfo.processInfo.environment
                environment["ELECTRON_RUN_AS_NODE"] = "1"
                process.environment = environment
            }
            let pipe = Pipe()
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
                defer { timeout.cancel() }
                try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                try pipe.fileHandleForWriting.close()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return }
            } catch { continue }
        }
        throw HookError.message(
            available
                ? "DeepSeek Harness patch 格式不正确，原配置已保留。"
                : "需要官方 DeepSeek Harness 客户端或 CLI 来校验现有 patch，原配置已保留。")
    }
}
