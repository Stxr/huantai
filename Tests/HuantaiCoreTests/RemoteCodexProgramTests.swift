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

    func testBotmuxAcknowledgedSendsReplaceSilentMarkersAndIgnoreActivity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let rootJSON = String(data: try encoder.encode(directory.path), encoding: .utf8)!
        let setup = """
            import pathlib, sqlite3, json
            root_arg = \(rootJSON)
            root = pathlib.Path(root_arg)
            botmux_root_arg = str(root / 'botmux')
            (root / 'sessions').mkdir()
            log = root / 'sessions' / 'rollout.jsonl'
            log.write_text(json.dumps(dict(timestamp='2026-10-21T08:00:00Z', type='response_item', payload=dict(type='message', role='assistant', phase='final_answer', content=[dict(type='output_text', text='BOTMUX_NOTHING_TO_SEND')]))))
            with log.open('a') as f:
                f.write('\\n' + json.dumps(dict(timestamp='2026-10-21T09:00:00Z', type='event_msg', payload=dict(type='task_complete', last_agent_message='BOTMUX_NOTHING_TO_SEND\\n\\nBOTMUX_NO_REPLY'))))
            db = sqlite3.connect(root / 'state_5.sqlite')
            db.execute('CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, rollout_path TEXT)')
            ids = ['019f9d97-401f-7942-b6ba-4cda42ca604' + str(i) for i in range(3)]
            for sid in ids:
                db.execute('INSERT INTO threads VALUES (?, ?, ?, ?)', (sid, 'fixture', '/workspace', str(log)))
            db.commit()
            db.close()
            botmux = pathlib.Path(botmux_root_arg)
            sends = botmux / 'turn-sends'
            sends.mkdir(parents=True)
            (botmux / 'sessions.json').write_text(json.dumps([dict(sessionId=sid, cliSessionId=sid, cliId='codex', scope='chat', chatId='oc_fixture', lastMessageAt='2026-10-21T10:00:00Z') for sid in ids]))
            records = [dict(sentAtMs=1792572298696, messageId='om_success', previewText='Actual sent reply'), dict(sentAtMs=1792572398696, previewText='Unacknowledged'), dict(sentAtMs='1792572498696', messageId='om_bad'), dict(sentAtMs=1792572598696, messageId='')]
            (sends / (ids[0] + '.jsonl')).write_text('\\n'.join(json.dumps(r) for r in records) + '\\nmalformed')
            outside = root / 'outside.jsonl'
            outside.write_text(json.dumps(records[0]))
            (sends / (ids[1] + '.jsonl')).symlink_to(outside)
            """
        let (status, output) = try runProgram(setup: setup, in: directory)
        XCTAssertEqual(status, 0)
        let target = RemoteTarget(
            id: "fixture", name: "fixture", host: "example", sessionRoot: directory.path)
        let rows = try RemoteCodexReader.decode(output, target: target)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].lastAIReplyAt?.timeIntervalSince1970, 1_792_572_298.696)
        XCTAssertEqual(rows[0].lastAIReplyPreview, "Actual sent reply")
        XCTAssertNil(rows[1].lastAIReplyAt, "Linked send logs must not be read")
        XCTAssertNil(rows[2].lastAIReplyAt, "Human activity and silent markers are not replies")
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
            routes.execute('INSERT INTO sessions VALUES (?)', (json.dumps(dict(cliId='codex', cliSessionId='019f9d97-401f-7942-b6ba-4cda42ca6040', scope='thread', chatId='oc_fixture', larkThreadId='omt_topic', rootMessageId='om_root')),))
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
        let target = RemoteTarget(
            id: "fixture", name: "合成远端", host: "example", sessionRoot: root.path, botmuxEnabled: true)
        let rawRows = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [[String: Any]])
        let routes = try XCTUnwrap(rawRows.first?["botmux"] as? [[String: Any]])
        XCTAssertEqual(routes.first?["rootMessageId"] as? String, "om_root")
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
        let disabledSetup = """
            root_arg = \(rootJSON)
            botmux_root_arg = None
            """
        let (disabledStatus, disabledOutput) = try runProgram(setup: disabledSetup, in: directory)
        XCTAssertEqual(disabledStatus, 0)
        let disabledRows = try RemoteCodexReader.decode(disabledOutput, target: target)
        XCTAssertEqual(disabledRows.count, rows.count)
        XCTAssertTrue(
            disabledRows.allSatisfy {
                $0.source == "Codex"
                    && $0.openURL
                        == SourceOpening.codexURL(sessionID: $0.nativeSessionID, remoteHost: target.host)
            })
        XCTAssertEqual(disabledRows[0].tokenUsage, rows[0].tokenUsage)
    }
}
