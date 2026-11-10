import Foundation
import XCTest
@testable import HuantaiCore

final class RemoteSessionSearchTests: XCTestCase {
    func testRemoteFullHistoryAndPathBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let rootJSON = String(data: try encoder.encode(directory.path), encoding: .utf8)!
        let setup = """
            import json, pathlib, sqlite3
            args = dict(root=\(rootJSON), query='深度needle')
            root = pathlib.Path(args['root'])
            (root / 'archived_sessions').mkdir()
            def message(role, phase, text):
                return json.dumps(dict(type='response_item', payload=dict(type='message', role=role, phase=phase, content=[dict(type='text', text=text)])))
            early = root / 'archived_sessions' / 'early.jsonl'
            early.write_text(message('user', None, '深度NEEDLE') + '\\n' + ('{}\\n' * 3000000))
            final = root / 'archived_sessions' / 'final.jsonl'
            final.write_text(message('assistant', 'final_answer', '深度needle'))
            ignored = root / 'archived_sessions' / 'ignored.jsonl'
            ignored.write_text(message('assistant', 'commentary', '深度needle') + '\\n' + message('system', None, '深度needle'))
            outside = root / 'outside.jsonl'
            outside.write_text(message('user', None, '深度needle'))
            (root / 'sessions').symlink_to(root, target_is_directory=True)
            db = sqlite3.connect(root / 'state_5.sqlite')
            db.execute('CREATE TABLE threads (id TEXT, rollout_path TEXT)')
            for sid, path in [('early', early), ('final', final), ('ignored', ignored), ('outside', root / 'sessions' / 'outside.jsonl')]:
                db.execute('INSERT INTO threads VALUES (?, ?)', (sid, str(path)))
            db.commit()
            db.close()
            """
        let script = directory.appendingPathComponent("search.py")
        let output = directory.appendingPathComponent("result.json")
        try Data((setup + "\n" + RemoteSessionSearchProgram.script).utf8).write(to: script)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = try Data(contentsOf: output)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(result["ids"] as? [String] ?? []), ["early", "final"])
        XCTAssertEqual(result["unreadable"] as? Int, 1)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("needle"))
    }
}
