from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import threading
import uuid
from zoneinfo import ZoneInfo

DEFAULT_THRESHOLDS = [0, 1_000_000, 3_000_000, 6_000_000, 10_000_000, 20_000_000,
                      40_000_000, 80_000_000, 140_000_000, 240_000_000, 400_000_000, 650_000_000]
MAX_LINE = 4 * 1024 * 1024


def integer(value):
    return value if type(value) is int and 0 <= value <= 9_223_372_036_854_775_807 else None


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed if parsed.tzinfo else None
    except (AttributeError, ValueError):
        return None


def safe_model(value):
    return value if isinstance(value, str) and re.fullmatch(r'[\w./-]{1,64}', value, re.ASCII) else 'unknown-model'


class Ledger:
    def __init__(self, path, now=None):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS files(key TEXT PRIMARY KEY, inode TEXT, offset INTEGER, total INTEGER, model TEXT);
        CREATE TABLE IF NOT EXISTS seen(fingerprint TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS meals(fingerprint TEXT PRIMARY KEY, date TEXT, model TEXT, tokens INTEGER);
        CREATE TABLE IF NOT EXISTS actions(id TEXT PRIMARY KEY, result INTEGER NOT NULL);
        ''')
        with self.lock, self.db:
            if self.get('epoch') is None:
                self.set('epoch', uuid.uuid4().hex)
                self.set('adopted_at', (now or datetime.now(timezone.utc)).isoformat())
                self.set('timezone', 'Asia/Shanghai')
                self.set('family', 0)
                self.set('source', 'local')
                self.set('seq', 1)
                self.set('thresholds', DEFAULT_THRESHOLDS)

    def get(self, key, default=None):
        row = self.db.execute('SELECT value FROM meta WHERE key=?', (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set(self, key, value):
        self.db.execute('INSERT OR REPLACE INTO meta VALUES(?,?)', (key, json.dumps(value)))

    def configure(self, family=None, source=None, thresholds=None, transport=None):
        with self.lock, self.db:
            if family is not None:
                raise ValueError('Choose a partner through adoption')
            if transport is not None:
                if transport not in ('auto', 'usb', 'ble'):
                    raise ValueError('Invalid device transport')
                self.set('transport', transport)
            if source is not None:
                if source not in ('local', 'account'):
                    raise ValueError('Invalid token source')
                if source != self.get('source'):
                    self.set('source', source)
                    if source == 'account':
                        self.set('account_rebaseline', True)
                    else:
                        self.set('local_initialized', False)
            if thresholds is not None:
                if len(thresholds) != 12 or thresholds[0] != 0 or any(integer(x) is None for x in thresholds) or any(a >= b for a, b in zip(thresholds, thresholds[1:])):
                    raise ValueError('Twelve strictly increasing thresholds required')
                self.set('thresholds', thresholds)
            self.set('seq', self.get('seq') + 1)

    def adopt(self, family):
        with self.lock, self.db:
            if type(family) is not int or not 0 <= family < 6:
                raise ValueError('Invalid evolution family')
            if self.get('adopted', False):
                if family == self.get('family'): return  # Retry is idempotent.
                raise ValueError('Partner is locked')
            self.set('family', family)
            self.set('adopted', True)
            self.set('partner_chosen_at', datetime.now(timezone.utc).isoformat())
            self.set('seq', self.get('seq') + 1)

    def _records(self, handle):
        while True:
            start = handle.tell()
            line = handle.readline(MAX_LINE + 1)
            if not line:
                break
            if not line.endswith(b'\n'):
                if len(line) <= MAX_LINE:
                    handle.seek(start)  # Wait for a complete record before moving the cursor.
                    break
                while line and not line.endswith(b'\n'):
                    line = handle.readline(MAX_LINE + 1)
                yield handle.tell(), None
                continue
            if len(line) > MAX_LINE:
                yield handle.tell(), None
                continue
            try:
                item = json.loads(line)
            except (ValueError, UnicodeError):
                item = None
            yield handle.tell(), item if isinstance(item, dict) else None

    @staticmethod
    def _token_record(record, model):
        payload = record.get('payload')
        if not isinstance(payload, dict):
            return None, model
        if record.get('type') == 'turn_context':
            return None, safe_model(payload.get('model'))
        if record.get('type') != 'event_msg' or payload.get('type') != 'token_count':
            return None, model
        info = payload.get('info')
        if not isinstance(info, dict) or not isinstance(info.get('total_token_usage'), dict):
            return None, model
        return info, model

    def initialize_baselines(self, paths):
        """Existing history establishes cursors, never an immediate meal."""
        with self.lock, self.db:
            if self.get('local_initialized'):
                return
            for path in paths:
                if path.is_symlink() or not path.is_file():
                    continue
                stat = path.stat()
                total = None
                model = 'unknown-model'
                with path.open('rb') as handle:
                    # Bounded tail inspection avoids parsing entire historical conversations.
                    if stat.st_size > 2 * MAX_LINE:
                        handle.seek(stat.st_size - 2 * MAX_LINE)
                        handle.readline()
                    offset = handle.tell()
                    for offset, record in self._records(handle):
                        if record is None:
                            continue
                        info, model = self._token_record(record, model)
                        if info:
                            count = integer(info['total_token_usage'].get('total_tokens'))
                            if count is not None:
                                total = count
                self.db.execute('INSERT OR REPLACE INTO files VALUES(?,?,?,?,?)',
                                (self.file_key(path), f'{stat.st_dev}:{stat.st_ino}', offset, total, model))
            self.set('local_initialized', True)

    @staticmethod
    def file_key(path):
        # Rename/move to archived_sessions retains a Codex UUID filename identity.
        match = re.search(r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$', path.name)
        key = match.group(1) if match else str(path.resolve())
        return hashlib.sha256(key.encode()).hexdigest()

    def scan_file(self, path):
        path = Path(path)
        if path.is_symlink() or not path.is_file():
            return 0
        stat = path.stat()
        identity = f'{stat.st_dev}:{stat.st_ino}'
        key = self.file_key(path)
        with self.lock, self.db:
            row = self.db.execute('SELECT * FROM files WHERE key=?', (key,)).fetchone()
            changed = row is not None and (row['inode'] != identity or stat.st_size < row['offset'])
            offset = 0 if row is None or changed else row['offset']
            previous = None if row is None or changed else row['total']
            model = 'unknown-model' if row is None or changed else row['model']
            if stat.st_size == offset:
                return 0
            added = 0
            cutoff = timestamp(self.get('adopted_at'))
            zone = ZoneInfo(self.get('timezone'))
            with path.open('rb') as handle:
                handle.seek(offset)
                for offset, record in self._records(handle):
                    if record is None:
                        continue
                    info, model = self._token_record(record, model)
                    if not info:
                        continue
                    usage = info['total_token_usage']
                    total = integer(usage.get('total_tokens'))
                    last = info.get('last_token_usage')
                    last_total = integer(last.get('total_tokens')) if isinstance(last, dict) else None
                    if total is None:
                        continue
                    when = timestamp(record.get('timestamp'))
                    if previous is None:
                        delta = min(total, last_total or 0)
                    elif total < previous:
                        # A reset/replacement is a new baseline, not a negative meal or a huge jump.
                        delta = 0
                        self.set('counter_resets', self.get('counter_resets', 0) + 1)
                    else:
                        delta = total - previous
                    previous = total
                    if when is None or when < cutoff:
                        continue
                    # A copied fork event keeps its original timestamp and counters. Do not feed twice.
                    fingerprint = hashlib.sha256(json.dumps(
                        [record['timestamp'], model, usage, last], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
                    fresh = self.db.execute('INSERT OR IGNORE INTO seen VALUES(?)', (fingerprint,)).rowcount
                    if fresh and delta and self.get('source') == 'local' and self.get('adopted', False):
                        self.db.execute('INSERT INTO meals VALUES(?,?,?,?)',
                                        (fingerprint, when.astimezone(zone).date().isoformat(), model, delta))
                        added += delta
            self.db.execute('INSERT OR REPLACE INTO files VALUES(?,?,?,?,?)', (key, identity, offset, previous, model))
            if added:
                self.set('seq', self.get('seq') + 1)
            return added

    def update_account(self, payload, now=None):
        now = now or datetime.now(timezone.utc)
        summary = payload.get('summary', {})
        total = integer(summary.get('lifetimeTokens'))
        buckets = payload.get('dailyUsageBuckets')
        latest = max((b['startDate'] for b in buckets), default=None) if isinstance(buckets, list) else None
        with self.lock, self.db:
            previous = self.get('account_total')
            self.set('account_latest_date', latest)
            self.set('account_read_at', now.isoformat())
            if total is None:
                self.set('account_status', 'unknown')
                return 0
            self.set('account_status', 'ok')
            self.set('account_total', total)
            rebaseline = self.get('account_rebaseline', False)
            self.set('account_rebaseline', False)
            delta = 0 if previous is None or rebaseline else max(0, total - previous)
            if delta and self.get('source') == 'account' and self.get('adopted', False):
                # This is ingestion-date attribution; server daily buckets are displayed separately.
                fingerprint = hashlib.sha256(f'account:{previous}:{total}'.encode()).hexdigest()
                if self.db.execute('INSERT OR IGNORE INTO seen VALUES(?)', (fingerprint,)).rowcount:
                    self.db.execute('INSERT INTO meals VALUES(?,?,?,?)',
                                    (fingerprint, now.astimezone(ZoneInfo(self.get('timezone'))).date().isoformat(), 'account-token', delta))
                    self.set('seq', self.get('seq') + 1)
                    return delta
            return 0

    def snapshot(self, now=None):
        now = now or datetime.now(timezone.utc)
        with self.lock, self.db:
            date = now.astimezone(ZoneInfo(self.get('timezone'))).date().isoformat()
            if date != self.get('display_date'):
                self.set('display_date', date)
                self.set('seq', self.get('seq') + 1)
            total = self.db.execute('SELECT COALESCE(SUM(tokens),0) FROM meals').fetchone()[0]
            today = self.db.execute('SELECT COALESCE(SUM(tokens),0) FROM meals WHERE date=?', (date,)).fetchone()[0]
            food = [dict(row) for row in self.db.execute('SELECT model,SUM(tokens) AS tokens FROM meals WHERE date=? GROUP BY model ORDER BY tokens DESC', (date,))]
            thresholds = self.get('thresholds')
            level = max(self.get('highest_level', 1), max(i + 1 for i, threshold in enumerate(thresholds) if total >= threshold))
            self.set('highest_level', level)
            low = thresholds[level - 1]
            high = thresholds[level] if level < 12 else low
            progress = 100 if level == 12 else max(0, min(100, int(100 * (total - low) / (high - low))))
            return {'epoch': self.get('epoch'), 'seq': self.get('seq'), 'date': date,
                    'timezone': self.get('timezone'), 'transport': self.get('transport','auto'), 'source': self.get('source'), 'family': self.get('family'),
                    'adopted': self.get('adopted', False), 'level': level, 'progress': progress, 'tokens_today': today, 'pet_tokens_total': total,
                    'next_threshold': high, 'thresholds': thresholds, 'food': food,
                    'adopted_at': self.get('adopted_at'), 'account_total': self.get('account_total'),
                    'account_latest_date': self.get('account_latest_date'), 'account_status': self.get('account_status', 'pending'),
                    'account_read_at': self.get('account_read_at'), 'counter_resets': self.get('counter_resets', 0)}

    def close(self):
        self.db.close()
