import Foundation

/// Reads official DSH session artifacts without invoking the Harness or changing its storage.
final class DeepSeekHarnessScanner {
    private struct Stamp: Equatable {
        var size: Int
        var modified: Date?
        var inode: UInt64?
    }
    private struct Cached {
        var stamp: Stamp
        var session: SessionRecord
    }
    private var cache: [String: Cached] = [:]

    func reset() { cache.removeAll() }

    func scan(home: URL, diagnostics: inout ScanDiagnostics) throws -> (
        sessions: [SessionRecord], unreadable: Int
    ) {
        let root = home.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("sessions")
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw HuantaiError.sourceUnavailable("会话目录是软链接")
        }
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw HuantaiError.sourceUnavailable("会话目录不存在")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        var traversalFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    traversalFailed = true
                    return false
                }
            )
        else { throw HuantaiError.sourceUnavailable("会话目录不可读") }
        var artifacts: [String: (url: URL, version: Int)] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, let version = Self.generation(url.lastPathComponent),
                url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
            else { continue }
            let directory = url.deletingLastPathComponent().path
            if artifacts[directory].map({ $0.version > version }) == true { continue }
            // During publication both encodings can coexist; prefer the newer artifact at the same generation.
            if let old = artifacts[directory], old.version == version {
                let oldDate =
                    try old.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    ?? .distantPast
                let newDate =
                    try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    ?? .distantPast
                if newDate <= oldDate { continue }
            }
            artifacts[directory] = (url, version)
        }
        guard !traversalFailed else { throw HuantaiError.sourceUnavailable("会话目录读取失败") }
        var sessions: [SessionRecord] = []
        var unreadable = 0
        var seen = Set<String>()
        for artifact in artifacts.values {
            let url = artifact.url
            seen.insert(url.path)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let stamp = Stamp(
                    size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                    modified: attributes[.modificationDate] as? Date,
                    inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
                if let old = cache[url.path], old.stamp == stamp {
                    sessions.append(old.session)
                    diagnostics.unchangedFiles += 1
                    continue
                }
                guard stamp.size <= 64 * 1024 * 1024 else { throw HuantaiError.sourceUnavailable("会话记录过大") }
                let data = try url.pathExtension == "zstd" ? Self.decompress(url) : Data(contentsOf: url)
                let session = try Self.metadata(
                    in: data, version: artifact.version, directory: url.deletingLastPathComponent())
                cache[url.path] = Cached(stamp: stamp, session: session)
                sessions.append(session)
                diagnostics.fullReadFiles += 1
                diagnostics.bytesRead += UInt64(data.count)
            } catch {
                unreadable += 1
                if let old = cache[url.path] { sessions.append(old.session) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return (sessions, unreadable)
    }

    private static func generation(_ name: String) -> Int? {
        let plain = name.hasSuffix(".zstd") ? String(name.dropLast(5)) : name
        if plain == "session.jsonl" { return 0 }
        guard plain.range(of: "^session\\.v[1-9][0-9]*\\.jsonl$", options: .regularExpression) != nil else {
            return nil
        }
        return Int(plain.dropFirst(9).dropLast(6))
    }

    private struct Header: Decodable {
        var type: String
        var version: Int
        var id: String
        var cwd: String?
    }
    private struct Event: Decodable {
        var type: String
        var time: Double?
        var data: Payload?
        struct Payload: Decodable {
            var title: String?
            var message: Message?
        }
        struct Message: Decodable {
            var role: String?
            var content: [Part]?
        }
        struct Part: Decodable {
            var type: String?
            var text: String?
        }
    }

    private static func metadata(in data: Data, version: Int, directory: URL) throws -> SessionRecord {
        let lines = data.split(separator: 10)
        let decoder = JSONDecoder()
        guard let first = lines.first, let header = try? decoder.decode(Header.self, from: Data(first)),
            header.type == "session", header.version == version, (0...4).contains(version),
            header.id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
            directory.lastPathComponent.removingPercentEncoding == header.id
        else {
            throw HuantaiError.sourceUnavailable("会话格式或标识暂不支持")
        }
        var title = "DeepSeek Harness 会话"
        var latest: Date?
        var preview: String?
        for line in lines.dropFirst() where line.count <= 32 * 1024 * 1024 {
            guard let event = try? decoder.decode(Event.self, from: Data(line)) else { continue }
            if event.type == "session/title", let value = clean(event.data?.title, limit: 200) {
                title = value
            }
            guard event.type == "assistant/message", event.data?.message?.role == "assistant",
                let text = clean(
                    event.data?.message?.content?.filter { $0.type == "text" }.compactMap(\.text).joined(
                        separator: " "), limit: 320),
                let time = event.time, time.isFinite, time > 0
            else { continue }
            let date = Date(timeIntervalSince1970: time / 1000)
            if latest == nil || date >= latest! {
                latest = date
                preview = text
            }
        }
        return SessionRecord(
            id: "dsh:" + header.id, title: title, cwd: clean(header.cwd, limit: 1000) ?? "",
            source: "DeepSeek Harness", machine: "本机", lastAIReplyAt: latest,
            lastAIReplyPreview: preview, openURL: SourceOpening.deepSeekHarnessURL)
    }

    private static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let value = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let plain = String(String.UnicodeScalarView(value)).split(whereSeparator: \.isWhitespace).joined(
            separator: " ")
        return plain.isEmpty ? nil : String(plain.prefix(limit))
    }

    private static func decompress(_ url: URL) throws -> Data {
        let fm = FileManager.default
        // Node 24+ and the official Electron runtime provide the same built-in Zstandard decoder.
        let nodeCandidates = [
            "/opt/homebrew/bin/node", "/usr/local/bin/node",
            "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness",
            fm.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"
            ).path,
        ]
        for executable in nodeCandidates where fm.isExecutableFile(atPath: executable) {
            // The public one-shot API decodes one frame. Official DSH appends independent frames.
            // Locate each complete frame using the Zstandard frame/block headers, then decode it.
            let script = """
                const b=require('node:fs').readFileSync(process.argv[1]), z=require('node:zlib');
                let p=0,total=0;
                outer: while(p<b.length) {
                  const start=p;
                  if(p+4>b.length) break;
                  const magic=b.readUInt32LE(p);
                  if(magic>=0x184d2a50 && magic<=0x184d2a5f) {
                    if(p+8>b.length) break;
                    const end=p+8+b.readUInt32LE(p+4);
                    if(end>b.length) break;
                    p=end;continue;
                  }
                  if(magic!==0xfd2fb528) throw Error('invalid frame');
                  if(p+5>b.length) break;
                  const d=b[p+4], single=!!(d&32), size=d>>>6;
                  if(d&8) throw Error('reserved descriptor');
                  p+=5+(single?0:1)+[0,1,2,4][d&3]+(size?(1<<size):(single?1:0));
                  if(p>b.length) break;
                  for(;;) {
                    if(p+3>b.length) break outer;
                    const block=b.readUIntLE(p,3),type=(block>>>1)&3;
                    if(type===3) throw Error('reserved block');
                    p+=3+(type===1?1:(block>>>3));
                    if(p>b.length) break outer;
                    if(block&1) break;
                  }
                  if(d&4) p+=4;
                  if(p>b.length) break;
                  const data=z.zstdDecompressSync(b.subarray(start,p),{maxOutputLength:134217728-total});
                  total+=data.length;process.stdout.write(data);
                }
                """
            if let data = try? run(
                executable, arguments: ["-e", script, url.path],
                electron: executable.hasSuffix("/DeepSeek Harness"))
            {
                return data
            }
        }
        for executable in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
        where fm.isExecutableFile(atPath: executable) {
            if let data = try? run(executable, arguments: ["-dc", "--", url.path]) { return data }
        }
        throw HuantaiError.sourceUnavailable("压缩会话需要 Node.js 24+、官方桌面客户端或 zstd")
    }

    private static func run(_ executable: String, arguments: [String], electron: Bool = false) throws -> Data
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if electron {
            var environment = ProcessInfo.processInfo.environment
            environment["ELECTRON_RUN_AS_NODE"] = "1"
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer {
            timeout.cancel()
            try? pipe.fileHandleForReading.close()
        }
        var result = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if result.count + chunk.count > 128 * 1024 * 1024 {
                process.terminate()
                throw HuantaiError.sourceUnavailable("解压记录过大")
            }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HuantaiError.sourceUnavailable("压缩记录不可读") }
        return result
    }
}
