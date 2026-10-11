import Foundation

/// Routing metadata only. Never infer a destination from a title or fall back from a topic to its chat.
struct RemoteBotmuxRoute: Decodable {
    var scope: String?
    var chatId: String?
    var larkThreadId: String?

    var url: String? {
        if scope == "chat" { return SourceOpening.feishuChatURL(chatID: chatId ?? "") }
        if scope == "thread" {
            return SourceOpening.feishuThreadURL(chatID: chatId ?? "", threadID: larkThreadId ?? "")
        }
        return nil
    }

    static func opening(_ routes: [Self]) -> (url: String?, reason: String?) {
        let urls = Set(routes.compactMap(\.url))
        if urls.count == 1 { return (urls.first, nil) }
        return (nil, urls.isEmpty ? "远端 Botmux 缺少有效的飞书聊天或话题 ID，可显式设置来源链接。" : "远端 Botmux 关联多个飞书目标，请显式设置来源链接。")
    }
}

enum RemoteBotmuxProgram {
    static let script = #"""
        import pathlib, sqlite3, json

        def botmux_routes(root_arg):
            root = pathlib.Path(root_arg).expanduser().resolve()
            stores = {}
            for p in sorted(root.glob('sessions-*.json')):
                stores[p.stem[len('sessions-'):]] = p
            if (root / 'sessions.json').exists(): stores[''] = root / 'sessions.json'
            for p in sorted((root / 'session-stores').glob('*/sessions.db')):
                stores[p.parent.name] = p
            if (root / 'sessions.db').exists(): stores[''] = root / 'sessions.db'
            result = {}
            fields = ['cliSessionId', 'cliId', 'scope', 'chatId', 'larkThreadId']
            for path in list(stores.values())[:32]:
                try:
                    if path.is_symlink() or root not in path.resolve().parents: continue
                    if path.suffix == '.db':
                        db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.5)
                        try:
                            sql = 'SELECT ' + ','.join("json_extract(row, '$." + field + "')" for field in fields) + ' FROM sessions WHERE json_valid(row)'
                            rows = [dict(zip(fields, row)) for row in db.execute(sql)]
                        finally: db.close()
                    else:
                        with path.open('rb') as f:
                            data = f.read(8 * 1024 * 1024 + 1)
                        if len(data) > 8 * 1024 * 1024: continue
                        data = json.loads(data)
                        rows = data.values() if isinstance(data, dict) else data
                    for row in rows:
                        if not isinstance(row, dict) or row.get('cliId') not in (None, 'codex'): continue
                        session_id = row.get('cliSessionId')
                        if not isinstance(session_id, str) or not session_id: continue
                        route = {key: row.get(key) if isinstance(row.get(key), str) else None for key in ('scope', 'chatId', 'larkThreadId')}
                        result.setdefault(session_id, []).append(route)
                except (OSError, ValueError, TypeError, sqlite3.Error): continue
            return result
        """#
}
