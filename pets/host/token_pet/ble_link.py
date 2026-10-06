"""Encrypted BLE UART with a per-installation key provisioned through USB."""
import asyncio
import json
import time
import queue

SERVICE = '5f8f0001-2f76-4f47-9ef8-4bb38d901001'
RX = '5f8f0002-2f76-4f47-9ef8-4bb38d901001'
TX = '5f8f0003-2f76-4f47-9ef8-4bb38d901001'

class NotificationParser:
    def __init__(self): self.pending = bytearray()
    def feed(self, data):
        self.pending.extend(data)
        messages = []
        while b'\n' in self.pending:
            line, _, rest = self.pending.partition(b'\n'); self.pending[:] = rest
            if len(line) > 2048: continue
            try: item = json.loads(line)
            except (ValueError, UnicodeError): continue
            if isinstance(item, dict) and item.get('v') == 1: messages.append(item)
        if len(self.pending) > 8192: self.pending.clear()
        return messages

class BLELink:
    def __init__(self, key, getter, enabled, stop, on_action=None):
        self.on_action=on_action; self.outbox=queue.Queue()
        self.key, self.getter, self.enabled, self.stop = key, getter, enabled, stop
        self.status = {'status':'standby','transport':'ble','last_ack':None,'last_ack_at':None}
        self.sent = None; self.ack_at = 0
    async def write(self, client, data):
        # A conservative 20-byte chunk also works with the minimum ATT MTU.
        for offset in range(0,len(data),20):
            await client.write_gatt_char(RX,data[offset:offset+20],response=True)
    async def authenticate(self, client, authorized, timeout=3):
        payload=(json.dumps({'v':1,'type':'auth','key':self.key},separators=(',',':'))+'\n').encode()
        for _ in range(3):
            await self.write(client,payload)
            try:
                await asyncio.wait_for(authorized.wait(),timeout)
                return
            except asyncio.TimeoutError: pass
        raise TimeoutError('BLE authentication response unavailable')
    def poll_thread(self): asyncio.run(self.run())
    async def run(self):
        from .serial_link import wire_snapshot, wire_companion
        try:
            from bleak import BleakClient, BleakScanner
        except ImportError:
            self.status['status']='ble_dependency_missing'; return
        while not self.stop.is_set():
            if not self.enabled():
                self.status['status']='standby'; await asyncio.sleep(.5); continue
            self.status['status']='ble_scanning'
            try:
                devices=await BleakScanner.discover(timeout=3,service_uuids=[SERVICE])
                if not self.enabled(): continue
                if len(devices)!=1:
                    self.status['status']='ambiguous' if devices else 'ble_not_found'
                    await asyncio.sleep(2); continue
                disconnected=asyncio.Event(); authorized=asyncio.Event(); parser=NotificationParser()
                auth_failed=False
                def notify(_characteristic,data):
                    nonlocal auth_failed
                    for item in parser.feed(data):
                        if item.get('type')=='auth_ok': authorized.set()
                        elif item.get('type')=='error' and item.get('code') in ('auth_failed','auth_required'):
                            auth_failed=True; authorized.set()
                        elif item.get('type')=='ack' and self.sent and (item.get('epoch'),item.get('seq'))==self.sent:
                            self.ack_at=time.monotonic()
                            self.status={'status':'synced','transport':'ble','last_ack':item['seq'],'last_ack_at':time.time()}
                        elif item.get('type')=='error': self.status['status']='protocol_error'
                        elif item.get('type')=='action' and self.on_action: self.on_action(item)
                self.status['status']='ble_connecting'
                async with BleakClient(devices[0],disconnected_callback=lambda _:disconnected.set(),timeout=30) as client:
                    self.status['status']='ble_pairing'
                    # macOS automatically pairs when this encrypted characteristic is read.
                    hello=json.loads(bytes(await client.read_gatt_char(TX)).decode())
                    if hello.get('app')!='token-pet' or hello.get('v')!=1: raise ValueError('Unexpected firmware')
                    await client.start_notify(TX,notify)
                    await self.authenticate(client,authorized)
                    if auth_failed:
                        self.status['status']='ble_auth_failed'; await asyncio.sleep(3); continue
                    self.sent=None; self.ack_at=0; last_sent=0
                    while client.is_connected and not disconnected.is_set() and self.enabled() and not self.stop.is_set():
                        state=self.getter()
                        if time.monotonic()-last_sent>3 or self.sent!=(state['epoch'],state['seq']):
                            self.sent=(state['epoch'],state['seq'])
                            await self.write(client,wire_snapshot(state));last_sent=time.monotonic()
                            companion=wire_companion(state)
                            if companion: await self.write(client,companion)
                        while not self.outbox.empty():
                            await self.write(client,(json.dumps(self.outbox.get_nowait(),separators=(',',':'))+'\n').encode())
                        if not self.ack_at or time.monotonic()-self.ack_at>15:self.status['status']='syncing'
                        await asyncio.sleep(.3)
            except Exception as exc:
                # Never log device identifiers, credentials or private counters.
                name=type(exc).__name__
                self.status['status']='ble_permission_required' if ('NotAvailable' in name or 'permission' in str(exc).lower() or 'denied' in str(exc).lower()) else 'ble_connection_error'
                await asyncio.sleep(3)
        self.status['status']='disconnected'
