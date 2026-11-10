/// BotMux sends bypass Codex assistant messages. Read acknowledged sends, never session activity.
enum RemoteBotmuxReplyProgram {
    static let script = #"""
        import math, uuid

        def botmux_sent_reply(root, session_id):
            latest, preview = None, None
            try:
                if not isinstance(session_id, str) or str(uuid.UUID(session_id)) != session_id: return latest, preview
                path = root / 'turn-sends' / (session_id + '.jsonl')
                if path.is_symlink() or root not in path.resolve().parents: return latest, preview
                with path.open('rb') as stream:
                    stream.seek(0, 2)
                    start = max(0, stream.tell() - 1024 * 1024)
                    stream.seek(start)
                    lines = stream.read(1024 * 1024).split(b'\n')
                for line in lines[1:] if start else lines:
                    try:
                        item = json.loads(line)
                        stamp, message = item.get('sentAtMs'), item.get('messageId')
                        if type(stamp) not in (int, float) or not math.isfinite(stamp) or stamp <= 0: continue
                        if not isinstance(message, str) or not message.startswith('om_'): continue
                        if latest is None or stamp / 1000 >= latest:
                            latest = stamp / 1000
                            text = item.get('previewText')
                            preview = ' '.join(text.split())[:320] if isinstance(text, str) else None
                    except (ValueError, TypeError, AttributeError, OverflowError): continue
            except (OSError, ValueError, TypeError): pass
            return latest, preview
        """#
}
