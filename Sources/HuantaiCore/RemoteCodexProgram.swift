/// Read-only remote extractor. Only bounded previews and usage samples leave the host.
enum RemoteCodexProgram {
    static let script = #"""
        import pathlib, sqlite3, json, datetime, math
        home = pathlib.Path(root_arg).expanduser().resolve()
        dbs = [p for p in home.glob('state_*.sqlite') if p.stem[6:].isdigit()]
        if not dbs: raise RuntimeError('Codex index missing')
        db = max(dbs, key=lambda p: int(p.stem[6:]))
        c = sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=3)
        c.row_factory = sqlite3.Row
        allowed = [(home / name).resolve() for name in ('sessions', 'archived_sessions')]

        def tail_lines(path):
            with path.open('rb') as f:
                f.seek(0, 2)
                size = f.tell()
                start = max(0, size - 8 * 1024 * 1024)
                f.seek(start)
                data = f.read(size - start)
                lines = data.split(b'\n')
                return lines[1:] if start else lines

        def number(value):
            return int(value) if type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 9007199254740991 and int(value) == value else None

        def token_usage(lines):
            compacted = False
            for line in reversed(lines):
                try:
                    event = json.loads(line)
                    payload = event.get('payload') or {}
                    if event.get('type') == 'compacted' or (event.get('type') == 'event_msg' and payload.get('type') == 'context_compacted'):
                        compacted = True
                    if event.get('type') != 'event_msg' or payload.get('type') != 'token_count': continue
                    info = payload.get('info') or {}
                    total = number((info.get('total_token_usage') or {}).get('total_tokens'))
                    context = None if compacted else number((info.get('last_token_usage') or {}).get('input_tokens'))
                    if total is None and context is None: continue
                    at = event.get('timestamp')
                    return dict(totalTokens=total, contextTokens=context,
                                contextWindow=number(info.get('model_context_window')) or None,
                                measuredAt=at if isinstance(at, str) else None, compacted=compacted)
                except (ValueError, TypeError, AttributeError, OverflowError): pass
            return None

        def timestamp(value):
            result = value if type(value) in (int, float) else datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
            return result if math.isfinite(result) else None

        def reply_preview(lines):
            latest, text = None, None
            for line in lines:
                try:
                    event = json.loads(line)
                    payload = event.get('payload') or {}
                    body, date = None, event.get('timestamp')
                    if event.get('type') == 'response_item' and payload.get('type') == 'message' and payload.get('role') == 'assistant' and payload.get('phase') in (None, 'commentary', 'final_answer', 'final'):
                        body = ' '.join(part.get('text', '') for part in payload.get('content', []) if isinstance(part, dict))
                    elif event.get('type') == 'event_msg' and payload.get('type') == 'task_complete':
                        body = payload.get('last_agent_message')
                        date = payload.get('completed_at') or date
                    if body and date:
                        value = timestamp(date)
                        if value is not None and (latest is None or value >= latest): latest, text = value, ' '.join(body.split())[:320]
                except (ValueError, TypeError, AttributeError, OverflowError): pass
            return latest, text

        def read_rollout(path):
            try:
                p = pathlib.Path(path).resolve()
                if p.suffix != '.jsonl' or not any(root in p.parents for root in allowed): return None, None, None
                lines = tail_lines(p)
                reply, text = reply_preview(lines)
                return reply, text, token_usage(lines)
            except (OSError, ValueError, TypeError): return None, None, None

        def display_titles():
            titles = {}
            path = home / 'session_index.jsonl'
            if path.is_symlink(): return titles
            try:
                for line in tail_lines(path):
                    try:
                        item = json.loads(line)
                        title = item.get('thread_name')
                        if isinstance(title, str) and title.strip() and len(title) <= 160: titles[item['id']] = title
                    except (ValueError, TypeError, AttributeError, KeyError): pass
            except OSError: pass
            return titles

        titles = display_titles()
        rows = []
        for row in c.execute('SELECT id, title, cwd, rollout_path FROM threads'):
            reply, text, usage = read_rollout(row['rollout_path'])
            rows.append(dict(id=row['id'], title=titles.get(row['id'], row['title'] or '')[:1000],
                             cwd=(row['cwd'] or '')[:1000], reply=reply, preview=text, tokenUsage=usage))
        print(json.dumps(rows, allow_nan=False))
        """#
}
