"""Read the running Huantai app; open only a currently displayed session."""
from datetime import datetime, timezone
import hashlib
import json
import re
import threading
import time
from urllib.request import Request, build_opener, ProxyHandler

BASE = 'http://127.0.0.1:18784'

def display_text(value, limit=24):
    text = str(value or '')
    result = ''
    for ch in text:
        if len(result) >= limit: break
        if 32 <= ord(ch) <= 126:
            result += ch
        else:
            try: ch.encode('gb2312'); supported = ch.isprintable()
            except UnicodeError: supported = False
            result += ch if supported else '?'
    return result or '无标题会话'

class HuantaiBridge:
    def __init__(self, opener=None):
        self.http = opener or build_opener(ProxyHandler({})).open
        self.lock = threading.RLock()
        self.rows = {}
        self.last_read = 0
        self.data = {'available': False, 'sessions': [], 'quota': {'valid': False}}

    def read(self, path):
        with self.http(BASE + path, timeout=3) as response:
            data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024: raise ValueError('Oversized Huantai response')
        return data

    def refresh(self):
        try:
            raw = json.loads(self.read('/api/snapshot'))
            snapshot = raw['snapshot']
            # Match Huantai: incomplete sessions, latest visible AI reply first.
            rows = [r for r in snapshot['sessions'] if not r.get('isCompleted')]
            rows.sort(key=lambda r: (r.get('lastAIReplyAt') is None, -(datetime.fromisoformat(r['lastAIReplyAt'].replace('Z','+00:00')).timestamp() if r.get('lastAIReplyAt') else 0), r['id']))
            handles, sessions = {}, []
            for row in rows[:3]:
                handle = hashlib.sha256(row['id'].encode()).hexdigest()[:16]
                handles[handle] = row
                source = 'DSH' if row['source'] == 'DeepSeek Harness' else 'Codex' if 'codex' in row['source'].lower() else 'Botmux'
                sessions.append({'handle': handle, 'title': display_text(row['title']), 'source': source, 'openable': bool(row.get('openURL'))})
            usage = snapshot.get('usage', {})
            weekly = usage.get('weekly')
            projection = raw.get('usageProjection', {})
            quota = {'valid': False}
            if weekly:
                reset = datetime.fromisoformat(weekly['resetsAt'].replace('Z','+00:00')).timestamp()
                used = float(weekly['usedPercent'])
                if 0 <= used <= 100 and reset > 0:
                    quota = {'valid': True, 'remaining': round((100-used)*10), 'reset_at': int(reset),
                             'reset_text': datetime.fromtimestamp(reset).strftime('%m-%d')+'(周'+'一二三四五六日'[datetime.fromtimestamp(reset).weekday()]+') '+datetime.fromtimestamp(reset).strftime('%H:%M'),
                             'reference': round((100-projection['referenceBudgetPercent'])*10) if projection.get('referenceBudgetPercent') is not None else None,
                             'today': round(projection['todayReferenceRemainingPercent']*10) if projection.get('todayReferenceRemainingPercent') is not None else None,
                             'live': usage.get('source') == 'codex-app-server', 'observed_at': usage.get('observedAt')}
            with self.lock:
                self.rows = handles
                self.last_read = time.monotonic()
                self.data = {'available': True, 'sessions': sessions, 'quota': quota}
        except (OSError, ValueError, KeyError, TypeError):
            with self.lock:
                self.rows = {}
                self.data = {'available': False, 'sessions': [], 'quota': {'valid': False}}

    def snapshot(self):
        with self.lock:
            result = json.loads(json.dumps(self.data))
            if time.monotonic() - self.last_read > 15:
                result = {'available': False, 'sessions': [], 'quota': {'valid': False}}
            result['now'] = int(time.time())
            return result

    def open(self, handle):
        with self.lock:
            row = self.rows.get(handle)
            if not row or not row.get('openURL') or time.monotonic()-self.last_read > 15:
                raise ValueError('Session no longer available')
            session_id = row['id']
        # Use Huantai's own validation and native SourceOpening implementation.
        page = self.read('/').decode()
        match = re.search(r'<meta name="huantai-csrf" content="([a-f0-9]{64})">', page)
        if not match: raise ValueError('HuantaI request token unavailable')
        request = Request(BASE+'/api/open', data=json.dumps({'id':session_id}).encode(), headers={'Content-Type':'application/json','X-Huantai-CSRF':match[1]})
        with self.http(request, timeout=12) as response:
            if not json.loads(response.read(1024)).get('ok'): raise ValueError('Open failed')
