/// Full-history search executes on the configured host and returns IDs only.
enum RemoteSessionSearchProgram {
    static let script = BotmuxSearchProgram.script + "\n" + #"""
        import pathlib, sqlite3
        home = pathlib.Path(args['root']).expanduser().resolve()
        query = args['query'].casefold()
        dbs = [p for p in home.glob('state_*.sqlite') if p.stem[6:].isdigit()]
        if not dbs: raise RuntimeError('Codex index missing')
        db = max(dbs, key=lambda p: int(p.stem[6:]))
        if db.is_symlink(): raise RuntimeError('Codex index is a symlink')
        connection = sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=3)
        allowed = [home / name for name in ('sessions', 'archived_sessions')]

        def content_text(content):
            if isinstance(content, str): return content
            if not isinstance(content, list): return ''
            return '\n'.join(part['text'] for part in content if isinstance(part, dict)
                             and part.get('type') in (None, 'text', 'input_text', 'output_text')
                             and isinstance(part.get('text'), str))

        def texts(event):
            if not isinstance(event, dict): return []
            payload = event.get('payload')
            if not isinstance(payload, dict): return []
            if event.get('type') == 'response_item' and payload.get('type') == 'message':
                if payload.get('role') == 'user' or (payload.get('role') == 'assistant' and payload.get('phase') in (None, 'final_answer', 'final')):
                    return [content_text(payload.get('content'))]
            if event.get('type') == 'event_msg':
                sent = botmux_sent_text(payload)
                if sent is not None: return [sent]
                if payload.get('type') == 'user_message': return [payload.get('message')]
                if payload.get('type') == 'task_complete': return [payload.get('last_agent_message')]
            return []

        def matches(raw_path):
            path = pathlib.Path(raw_path).resolve()
            if path.suffix != '.jsonl' or not any(root in path.parents for root in allowed):
                raise ValueError('Rollout outside allowed directories')
            with path.open('rb') as stream:
                while True:
                    line = stream.readline(32 * 1024 * 1024 + 1)
                    if not line: return False
                    if len(line) > 32 * 1024 * 1024: raise ValueError('Message too large')
                    may_be_sent = b'"item_completed"' in line and b'botmux' in line
                    if not may_be_sent and not any(marker in line for marker in (b'"message"', b'"user_message"', b'"task_complete"', b'\\u')):
                        continue
                    try: event = json.loads(line)
                    except (ValueError, UnicodeError): continue
                    if any(query in text.casefold() for text in texts(event) if isinstance(text, str)):
                        return True

        ids, unreadable = [], 0
        for sid, path in connection.execute('SELECT id, rollout_path FROM threads'):
            try:
                if matches(path): ids.append(sid)
            except (OSError, ValueError, TypeError): unreadable += 1
        print(json.dumps(dict(ids=ids, unreadable=unreadable)))
        """#
}
