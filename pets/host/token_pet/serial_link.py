import fcntl
import json
import os
import select
import termios
import time
import queue


def wire_snapshot(state):
    result = {key: state[key] for key in ('epoch', 'seq', 'date', 'family', 'level', 'progress', 'source')}
    result.update({'v': 1, 'type': 'snapshot', 'tokens_today': str(state['tokens_today']),
                   'adopted': state.get('adopted', False),
                   'pet_tokens_total': str(state['pet_tokens_total']),
                   'food': [{'model': row['model'], 'tokens': str(row['tokens'])} for row in state['food'][:3]]})
    encoded = (json.dumps(result, ensure_ascii=True, separators=(',', ':')) + '\n').encode()
    if len(encoded) > 2048:
        raise ValueError('Snapshot exceeds bounded device protocol')
    return encoded

def wire_companion(state):
    value = state.get('companion')
    if value is None: return None
    quota = value['quota']
    result = {'v':1, 'type':'companion', 'available':value['available'], 'sessions':value['sessions'],
              'quota_valid':quota['valid'], 'remaining':quota.get('remaining',0),
              'reset_after':max(0,min(604800,quota.get('reset_at',0)-value['now'])),
              'reset_text':quota.get('reset_text',''), 'reference':quota.get('reference'),
              'today':quota.get('today'), 'live':quota.get('live',False)}
    encoded = (json.dumps(result,ensure_ascii=True,separators=(',',':'))+'\n').encode()
    if len(encoded)>2048: raise ValueError('Companion exceeds protocol limit')
    return encoded


class SerialLink:
    def __init__(self, discover, ble_key=None, on_action=None):
        self.on_action = on_action
        self.outbox = queue.Queue()
        self.discover = discover
        self.ble_key = ble_key
        self.ble_capable = False
        self.key_ready = False
        self.key_sent_at = 0
        self.fd = None
        self.original = None
        self.pending = bytearray()
        self.ready = False
        self.sent_seq = None
        self.last_sent = 0
        self.ack_monotonic = 0
        self.status = {'status': 'searching', 'last_ack': None, 'last_ack_at': None}
        self.device_state = {}
        self.last_status = 0

    def close(self):
        if self.fd is not None:
            try:
                if self.original is not None:
                    termios.tcsetattr(self.fd, termios.TCSANOW, self.original)
            except OSError:
                pass
            os.close(self.fd)
        self.fd = None
        self.pending.clear()
        self.ready = False
        self.key_ready = False
        self.ble_capable = False
        self.key_sent_at = 0
        self.device_state = {}
        self.last_status = 0

    def connect(self):
        devices = self.discover()
        if len(devices) != 1:
            self.status['status'] = 'ambiguous' if devices else 'disconnected'
            return
        self.fd = os.open(devices[0]['port'], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.original = termios.tcgetattr(self.fd)
            settings = self.original[:]
            settings[6] = self.original[6][:]
            settings[0] = settings[1] = settings[3] = 0
            settings[2] = (settings[2] & ~(termios.PARENB | termios.CSTOPB | termios.CSIZE | termios.HUPCL)) | termios.CS8 | termios.CREAD | termios.CLOCAL
            settings[4] = settings[5] = termios.B115200
            settings[6][termios.VMIN] = settings[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, settings)
            self.status['status'] = 'awaiting_pet_firmware'
        except Exception:
            self.close()
            raise

    def poll(self, state, send_snapshot=True):
        try:
            if self.fd is None:
                self.connect()
                if self.fd is None:
                    return
            while select.select([self.fd], [], [], 0)[0]:
                data = os.read(self.fd, 4096)
                if not data:
                    raise OSError('USB disconnected')
                self.pending.extend(data)
                while b'\n' in self.pending:
                    line, _, rest = self.pending.partition(b'\n')
                    self.pending[:] = rest
                    try:
                        message = json.loads(line)
                    except (ValueError, UnicodeError):
                        continue  # Ignore firmware logs and unrelated protocols.
                    if not isinstance(message, dict) or message.get('v') != 1:
                        continue
                    if message.get('type') == 'hello' and message.get('app') == 'token-pet':
                        self.ble_capable = message.get('ble') is True
                        self.ready = True
                        self.last_sent = 0
                    elif message.get('type') == 'ble_provisioned':
                        self.key_ready = True
                    elif message.get('type') == 'action' and self.on_action:
                        self.on_action(message)
                    elif message.get('type') == 'state':
                        self.device_state = {key:message[key] for key in ('adopted','family','page','session_count','quota_valid','free_heap','ble_connected','ble_authenticated','battery_percent','brightness_tier','brightness_percent','brightness_pwm_percent','mic_threshold_tier','mic_active_tier','mic_threshold_rms','preferences_saved','mic_ready','mic_rms','mic_floor','mic_peak','mic_blocks','mic_onsets','mic_stack_free','hop_offset','sprite_frame') if key in message}
                    elif message.get('type') == 'ack' and message.get('epoch') == state['epoch'] and message.get('seq') == self.sent_seq:
                        self.ack_monotonic = time.monotonic()
                        self.status = {'status': 'synced', 'last_ack': message['seq'], 'last_ack_at': time.time()}
                    elif message.get('type') == 'error':
                        self.status['status'] = 'protocol_error'
                if len(self.pending) > 8192:
                    self.pending.clear()
            if self.ready and (not self.ack_monotonic or time.monotonic() - self.ack_monotonic > 15):
                self.status['status'] = 'syncing'
            if self.ready and self.ble_capable and self.ble_key and not self.key_ready and time.monotonic() - self.key_sent_at > 5:
                self.write((json.dumps({'v':1,'type':'ble_provision','key':self.ble_key},separators=(',',':'))+'\n').encode())
                self.key_sent_at = time.monotonic()
            if self.ready and send_snapshot and time.monotonic() - self.last_sent > 3:
                self.sent_seq = state['seq']
                self.write(wire_snapshot(state))
                companion = wire_companion(state)
                if companion: self.write(companion)
                self.last_sent = time.monotonic()
            while self.ready and not self.outbox.empty():
                self.write((json.dumps(self.outbox.get_nowait(),separators=(',',':'))+'\n').encode())
            if self.ready and time.monotonic()-self.last_status>5:
                self.write(b'{"v":1,"type":"status"}\n')
                self.last_status=time.monotonic()
        except (OSError, ValueError):
            self.close()
            self.status['status'] = 'disconnected'

    def write(self, payload):
        view = memoryview(payload)
        deadline = time.monotonic() + 2
        while view:
            if time.monotonic() > deadline:
                raise OSError('USB write timeout')
            if select.select([], [self.fd], [], .1)[1]:
                view = view[os.write(self.fd, view):]
