from __future__ import annotations
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
import re
import queue
from pathlib import Path
import secrets
import signal
import sys
import threading
import time
from urllib.parse import urlsplit

from .ledger import Ledger
from .serial_link import SerialLink
from .ble_link import BLELink
from .huantai import HuantaiBridge

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from probe_account_usage import fetch_usage
from probe_hardware import discover


class Application:
    def __init__(self, state_dir, roots, usb=True, account=True, bluetooth=None):
        self.ledger = Ledger(Path(state_dir) / 'pet.sqlite')
        self.roots = roots
        self.stop = threading.Event()
        self.csrf = secrets.token_hex(24)
        self.catalogue = json.loads((ROOT / 'assets/catalogue.json').read_text())
        self.bluetooth = usb if bluetooth is None else bluetooth
        key_path = Path(state_dir) / 'ble.key'
        self.ble_key = None
        if self.bluetooth:
            if not key_path.exists():
                fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'w') as file: file.write(secrets.token_hex(32))
            key = key_path.read_text().strip()
            if re.fullmatch('[0-9a-f]{64}', key): self.ble_key = key
        self.actions = queue.Queue(maxsize=16)
        self.companion = HuantaiBridge()
        self.serial = SerialLink(discover, self.ble_key, lambda msg: self.enqueue_action(msg, 'usb'))
        self.ble = BLELink(self.ble_key, self.wire_state, self.ble_enabled, self.stop, lambda msg: self.enqueue_action(msg, 'ble'))
        self.usb = usb
        self.account = account
        self.health = {'local': 'starting', 'files': 0}
        self.threads = []
        self.account_wake = threading.Event()

    def files(self):
        result = set()
        for root in self.roots:
            if root.is_symlink():
                continue
            if root.is_file() and root.suffix == '.jsonl':
                result.add(root)
            elif root.is_dir():
                result.update(p for p in root.rglob('*.jsonl') if p.is_file() and not p.is_symlink())
        return result

    def scan_loop(self):
        while not self.stop.is_set():
            try:
                paths = self.files()
                self.ledger.initialize_baselines(paths)
                partial = False
                for path in paths:
                    if self.stop.is_set():
                        break
                    try:
                        self.ledger.scan_file(path)
                    except (OSError, ValueError):
                        partial = True
                self.health = {'local': 'partial' if partial else 'watching' if paths else 'no_files', 'files': len(paths)}
            except Exception:
                self.health['local'] = 'unavailable'
            self.stop.wait(5)

    def account_loop(self):
        import shutil
        executable = shutil.which('codex')
        if not executable:
            return
        while not self.stop.is_set():
            try:
                self.ledger.update_account(fetch_usage(executable, 20))
            except Exception:
                with self.ledger.lock, self.ledger.db:
                    self.ledger.set('account_status', 'unavailable')
            self.account_wake.wait(300)
            self.account_wake.clear()

    def ble_enabled(self):
        with self.ledger.lock:
            allowed = self.bluetooth and self.ble_key and self.ledger.get('ble_provisioned', False)
            mode = self.ledger.get('transport', 'auto')
        return bool(allowed and (mode == 'ble' or (mode == 'auto' and self.serial.fd is None)))

    def usb_loop(self):
        while not self.stop.is_set():
            try:
                state = self.wire_state()
                self.serial.poll(state, send_snapshot=state['transport'] != 'ble')
                if self.serial.key_ready:
                    with self.ledger.lock, self.ledger.db:
                        self.ledger.set('ble_provisioned', True)
            except Exception:
                self.serial.status['status'] = 'unavailable'
            self.stop.wait(1)
        self.serial.close()

    def wire_state(self):
        result = self.ledger.snapshot()
        result['companion'] = self.companion.snapshot()
        return result

    def companion_loop(self):
        while not self.stop.is_set():
            self.companion.refresh()
            self.stop.wait(5)

    def enqueue_action(self, message, transport):
        try: self.actions.put_nowait((message, transport))
        except queue.Full: pass  # Device retries its outstanding request.

    def action_loop(self):
        while not self.stop.is_set():
            try: message, transport = self.actions.get(timeout=.5)
            except queue.Empty: continue
            request = message.get('request')
            if not isinstance(request, str) or not re.fullmatch('[a-f0-9]{32}', request): continue
            with self.ledger.lock:
                old = self.ledger.db.execute('SELECT result FROM actions WHERE id=?',(request,)).fetchone()
            code = old[0] if old else 1
            if old is None:
                try:
                    if message.get('epoch') != self.ledger.snapshot()['epoch']: raise ValueError('Old profile')
                    if message.get('action') == 'adopt': self.ledger.adopt(message.get('family'))
                    elif message.get('action') == 'open' and self.ledger.get('adopted', False): self.companion.open(message.get('handle'))
                    else: raise ValueError('Invalid action')
                    code = 0
                except (ValueError, OSError, TypeError): code = 1
                with self.ledger.lock, self.ledger.db:
                    self.ledger.db.execute('INSERT OR IGNORE INTO actions VALUES(?,?)',(request,code))
            response = {'v':1,'type':'action_result','request':request,'code':code}
            (self.ble if transport == 'ble' else self.serial).outbox.put(response)

    def start(self):
        jobs = [self.scan_loop, self.companion_loop, self.action_loop]
        if self.account:
            jobs.append(self.account_loop)
        if self.usb:
            jobs.append(self.usb_loop)
        if self.bluetooth:
            jobs.append(self.ble.poll_thread)
        for job in jobs:
            thread = threading.Thread(target=job, daemon=True)
            thread.start()
            self.threads.append(thread)

    def state(self):
        result = self.ledger.snapshot()
        family = self.catalogue['families'][result['family']]
        result['species_id'] = family['species'][(result['level'] - 1) // 4]
        result['species'] = next(p for p in self.catalogue['pokemon'] if p['id'] == result['species_id'])
        use_ble = result['transport'] == 'ble' or (result['transport'] == 'auto' and self.usb and self.serial.fd is None and self.bluetooth)
        result['device'] = dict(self.ble.status) if use_ble else dict(self.serial.status, transport='usb') if self.usb else {'status': 'disabled'}
        result['bluetooth'] = {'available': self.bluetooth, 'provisioned': self.ledger.get('ble_provisioned', False), 'status': self.ble.status['status']}
        if use_ble and not result['bluetooth']['provisioned']:
            result['device']['status'] = 'ble_needs_usb'
        result['health'] = dict(self.health)
        result['companion'] = self.companion.snapshot()
        result['hardware'] = dict(self.serial.device_state)
        result['csrf'] = self.csrf
        # Decimal text stays exact in browsers even beyond Number.MAX_SAFE_INTEGER.
        for key in ('tokens_today', 'pet_tokens_total', 'next_threshold', 'account_total'):
            if result[key] is not None:
                result[key] = str(result[key])
        result['food'] = [{'model': row['model'], 'tokens': str(row['tokens'])} for row in result['food']]
        return result


def handler_for(app):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, data, content_type, status=200):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store' if content_type.startswith('application/json') else 'max-age=60')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(data)

        def json(self, value, status=200):
            self.send(json.dumps(value, ensure_ascii=False).encode(), 'application/json; charset=utf-8', status)

        def valid_host(self):
            return self.headers.get('Host') in (f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}')

        def do_GET(self):
            if not self.valid_host():
                return self.json({'error': 'Invalid host'}, 403)
            path = urlsplit(self.path).path
            if path == '/api/state':
                return self.json(app.state())
            if path == '/api/catalogue':
                return self.json(app.catalogue)
            mapping = {'/': ROOT / 'web/index.html', '/app.js': ROOT / 'web/app.js', '/style.css': ROOT / 'web/style.css'}
            if path.startswith('/assets/pokemon/'):
                filename = path.rsplit('/', 1)[-1]
                allowed = {f'{p["id"]}.{suffix}' for p in app.catalogue['pokemon'] for suffix in ('gif', 'png')}
                if filename in allowed:
                    mapping[path] = ROOT / 'assets/pokemon' / filename
            target = mapping.get(path)
            if not target or not target.is_file():
                return self.json({'error': 'Not found'}, 404)
            self.send(target.read_bytes(), (mimetypes.guess_type(target.name)[0] or 'application/octet-stream') + ('; charset=utf-8' if target.suffix in ('.html', '.js', '.css') else ''))

        def do_POST(self):
            origin = self.headers.get('Origin')
            allowed_origins = (f'http://127.0.0.1:{self.server.server_port}', f'http://localhost:{self.server.server_port}')
            if not self.valid_host() or (origin is not None and origin not in allowed_origins) or not secrets.compare_digest(self.headers.get('X-Pet-CSRF', ''), app.csrf):
                return self.json({'error': 'Request refused'}, 403)
            if self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                return self.json({'error': 'JSON required'}, 415)
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 2048:
                    raise ValueError()
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError()
                if self.path == '/api/adopt':
                    app.ledger.adopt(payload.get('family'))
                    return self.json(app.state())
                if self.path == '/api/open':
                    if not app.ledger.get('adopted', False): raise ValueError('Adopt first')
                    app.companion.open(payload.get('handle'))
                    return self.json({'ok': True})
                if self.path != '/api/config':
                    return self.json({'error': 'Not found'}, 404)
                app.ledger.configure(family=payload.get('family'), source=payload.get('source'), thresholds=payload.get('thresholds'), transport=payload.get('transport'))
                if payload.get('source') == 'account':
                    app.account_wake.set()
                return self.json(app.state())
            except (ValueError, TypeError, OSError):
                return self.json({'error': 'Invalid settings'}, 400)
    return Handler


def main():
    parser = argparse.ArgumentParser(description='Local Token Pet dashboard and USB bridge')
    parser.add_argument('--state-dir', type=Path, default=ROOT / '.local/state')
    parser.add_argument('--root', type=Path, action='append')
    parser.add_argument('--port', type=int, default=18785)
    parser.add_argument('--no-usb', action='store_true')
    parser.add_argument('--no-account', action='store_true')
    parser.add_argument('--no-bluetooth', action='store_true')
    args = parser.parse_args()
    roots = args.root or [Path.home() / '.codex/sessions', Path.home() / '.codex/archived_sessions']
    app = Application(args.state_dir, roots, not args.no_usb, not args.no_account, not args.no_bluetooth)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler_for(app))
    server.daemon_threads = True
    app.start()
    def stop(*_):
        app.stop.set()
        app.account_wake.set()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f'Token Pet: http://127.0.0.1:{server.server_port}/', flush=True)
    try:
        server.serve_forever()
    finally:
        app.stop.set()
        app.account_wake.set()
        for thread in app.threads:
            thread.join(timeout=22)
        server.server_close()
        app.ledger.close()


if __name__ == '__main__':
    main()
