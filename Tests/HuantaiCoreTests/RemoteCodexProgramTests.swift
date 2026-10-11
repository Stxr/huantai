import Foundation
import XCTest

@testable import HuantaiCore

final class RemoteCodexProgramTests: XCTestCase {
    func testRemoteProgramRejectsSymlinkedIndexesAndRolloutDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("codex")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let rootJSON = String(data: try encoder.encode(root.path), encoding: .utf8)!
        let logJSON = String(
            data: try JSONEncoder().encode(SessionTokenUsageTests.sample()), encoding: .utf8)!
        let setup = """
            import pathlib, sqlite3
            root_arg = \(rootJSON)
            root = pathlib.Path(root_arg)
            root.mkdir()
            botmux_root_arg = str(root / 'missing-botmux')
            outside = root.parent / 'outside'
            outside.mkdir()
            (outside / 'rollout.jsonl').write_text(\(logJSON))
            (root / 'sessions').symlink_to(outside, target_is_directory=True)
            db = sqlite3.connect(root / 'state_5.sqlite')
            db.execute('CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, rollout_path TEXT)')
            db.execute('INSERT INTO threads VALUES (?, ?, ?, ?)',
                       ('019f9d97-401f-7942-b6ba-4cda42ca604e', 'fixture', '/workspace', str(root / 'sessions' / 'rollout.jsonl')))
            db.commit()
            db.close()
            """
        let (status, output) = try runProgram(setup: setup, in: directory)
        XCTAssertEqual(status, 0)
        let target = RemoteTarget(id: "fixture", name: "fixture", host: "example", sessionRoot: root.path)
        let row = try XCTUnwrap(RemoteCodexReader.decode(output, target: target).first)
        XCTAssertNil(
            row.tokenUsage,
            "A linked sessions directory must not authorize reading outside the configured root")

        let index = root.appendingPathComponent("state_5.sqlite")
        let outsideIndex = directory.appendingPathComponent("outside.sqlite")
        try FileManager.default.moveItem(at: index, to: outsideIndex)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: outsideIndex)
        let linkedIndexSetup = """
            root_arg = \(rootJSON)
            botmux_root_arg = root_arg + '/missing-botmux'
            """
        let (linkedStatus, linkedOutput) = try runProgram(setup: linkedIndexSetup, in: directory)
        XCTAssertNotEqual(linkedStatus, 0, "A linked Codex index must be rejected, matching local reads")
        XCTAssertTrue(linkedOutput.isEmpty)
    }

    private func runProgram(setup: String, in directory: URL) throws -> (Int32, Data) {
        let script = directory.appendingPathComponent("read.py")
        try Data((setup + "\n" + RemoteCodexProgram.script).utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    func testRemoteProgramMatchesLocalUsageAndRejectsEscapingRollouts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("codex 'quoted'")
        let tokenLog = SessionTokenUsageTests.sample() + "\n{\"type\":\"compacted\"}\n"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let rootJSON = String(data: try encoder.encode(root.path), encoding: .utf8)!
        let logJSON = String(data: try JSONEncoder().encode(tokenLog), encoding: .utf8)!
        let setup = """
            import pathlib, sqlite3, json
            root_arg = \(rootJSON)
            root = pathlib.Path(root_arg)
            botmux_root_arg = str(root.parent / "botmux")
            (root / 'sessions').mkdir(parents=True)
            good = root / 'sessions' / 'good.jsonl'
            good.write_text(\(logJSON))
            outside = root.parent / 'outside.jsonl'
            outside.write_text(\(logJSON))
            link = root / 'sessions' / 'link.jsonl'
            link.symlink_to(outside)
            db = sqlite3.connect(root / 'state_5.sqlite')
            db.execute('CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, rollout_path TEXT)')
            for index, path in enumerate([good, link]):
                db.execute('INSERT INTO threads VALUES (?, ?, ?, ?)', ('019f9d97-401f-7942-b6ba-4cda42ca604' + str(index), 'old title', '/workspace', str(path)))
            db.commit()
            db.close()
            botmux = pathlib.Path(botmux_root_arg)
            store = botmux / 'session-stores' / 'fixture'
            store.mkdir(parents=True)
            routes = sqlite3.connect(store / 'sessions.db')
            routes.execute('CREATE TABLE sessions (row TEXT)')
            routes.execute('INSERT INTO sessions VALUES (?)', (json.dumps(dict(cliId='codex', cliSessionId='019f9d97-401f-7942-b6ba-4cda42ca6040', scope='thread', chatId='oc_fixture', larkThreadId='omt_topic')),))
            routes.execute('INSERT INTO sessions VALUES (?)', ('malformed',))
            routes.commit()
            routes.close()
            (botmux / 'sessions-fixture.json').write_text(json.dumps([dict(cliSessionId='019f9d97-401f-7942-b6ba-4cda42ca6040', scope='chat', chatId='oc_stale')]))
            (botmux / 'sessions.json').write_text(json.dumps(dict(chat=dict(cliId='codex', cliSessionId='019f9d97-401f-7942-b6ba-4cda42ca6041', scope='chat', chatId='oc_chat'))))
            (root / 'session_index.jsonl').write_text(json.dumps(dict(id='019f9d97-401f-7942-b6ba-4cda42ca6040', thread_name='Renamed task')) + '\\n')
            """
        let script = directory.appendingPathComponent("read.py")
        try Data((setup + "\n" + RemoteCodexProgram.script).utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let target = RemoteTarget(id: "fixture", name: "合成远端", host: "example", sessionRoot: root.path)
        let rows = try RemoteCodexReader.decode(output, target: target)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].title, "Renamed task")
        XCTAssertEqual(rows[0].tokenUsage, SessionTokenUsageScanner.decodeTail(Data(tokenLog.utf8)))
        XCTAssertNil(rows[1].tokenUsage)
        XCTAssertNil(rows[1].lastAIReplyPreview)
        XCTAssertEqual(rows[0].source, "Botmux")
        XCTAssertEqual(
            rows[0].openURL, SourceOpening.feishuThreadURL(chatID: "oc_fixture", threadID: "omt_topic"))
        XCTAssertEqual(rows[1].openURL, SourceOpening.feishuChatURL(chatID: "oc_chat"))
    }
}
