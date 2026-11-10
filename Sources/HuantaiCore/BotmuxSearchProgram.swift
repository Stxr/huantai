/// Mirrors BotmuxSentMessage for read-only extraction on SSH hosts.
enum BotmuxSearchProgram {
    static let script = #"""
        import re

        def botmux_sent_text(payload):
            if payload.get('type') != 'item_completed': return None
            item = payload.get('item')
            if not isinstance(item, dict) or item.get('type') != 'CommandExecution': return None
            if item.get('status') != 'completed' or item.get('exit_code') != 0: return None
            output, command = item.get('aggregated_output'), item.get('command')
            if not isinstance(output, str) or not isinstance(command, list) or not all(isinstance(s, str) for s in command): return None
            acknowledged = False
            for line in output.splitlines():
                try: result = json.loads(line)
                except ValueError: continue
                if isinstance(result, dict) and result.get('success') is True and isinstance(result.get('messageId'), str) and result['messageId'].startswith('om_'):
                    acknowledged = True
            if not acknowledged or not command: return None
            if command[0].split('/')[-1] == 'botmux' and command[1:2] == ['send'] and '--text' in command:
                index = command.index('--text')
                return command[index + 1] if index + 1 < len(command) else None
            if len(command) != 3 or command[0].split('/')[-1] not in ('bash', 'zsh', 'sh') or command[1] not in ('-c', '-lc'): return None
            lines = command[2].split('\n')
            if any(token in lines[0] for token in (';', '&', '|', '`', '$(')): return None
            if not re.match(r'^\s*(?:[^\s]+/)?botmux\s+send\b', lines[0]): return None
            match = re.search(r'''<<\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1\s*$''', lines[0])
            if not match or match[2] not in lines[1:]: return None
            end = lines.index(match[2], 1)
            if any(line.strip() for line in lines[end + 1:]): return None
            return '\n'.join(lines[1:end])
        """#
}
