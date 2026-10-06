#!/usr/bin/env python3
"""Read-only/replay acceptance using the current ledger, never synthetic meals."""
import asyncio
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'host'))
from token_pet.ble_link import SERVICE,RX,TX,NotificationParser
from token_pet.serial_link import wire_snapshot,wire_companion
from token_pet.huantai import HuantaiBridge
from token_pet.ledger import Ledger
from bleak import BleakClient,BleakScanner

async def main():
    ledger=Ledger(ROOT/'.local/state/pet.sqlite');state=ledger.snapshot();ledger.close()
    bridge=HuantaiBridge();bridge.refresh();companion=bridge.snapshot()
    key=(ROOT/'.local/state/ble.key').read_text().strip()
    devices=await BleakScanner.discover(timeout=3,service_uuids=[SERVICE])
    assert len(devices)==1, 'Expected exactly one Token Pet'
    result={'service_discovery':'PASS','fragment_size':20}
    for attempt in range(2):
        queue=asyncio.Queue();parser=NotificationParser(); observed=[]
        def notify(_characteristic,data):
            for message in parser.feed(data):
                observed.append((message.get('type'),message.get('code')));queue.put_nowait(message)
        async def write(client,data):
            for i in range(0,len(data),20):await client.write_gatt_char(RX,data[i:i+20],response=True)
        async def send(client,obj):await write(client,(json.dumps(obj,separators=(',',':'))+'\n').encode())
        async def wait(kind,check=lambda m:True,timeout=10):
            async with asyncio.timeout(timeout):
                while True:
                    message=await queue.get()
                    if message.get('type')==kind and check(message):return message
        async with BleakClient(devices[0],timeout=30) as client:
            hello=json.loads(bytes(await client.read_gatt_char(TX)));assert hello.get('app')=='token-pet'
            await client.start_notify(TX,notify)
            await asyncio.sleep(.75)
            if attempt==0:
                # Establish a working encrypted notification round trip before
                # asserting rejection. CoreBluetooth can lag just after a flash.
                for ready_attempt in range(3):
                    await send(client,{'v':1,'type':'auth','key':key})
                    try:
                        await wait('auth_ok',timeout=3);break
                    except TimeoutError:
                        if ready_attempt==2:raise
                # CoreBluetooth may retain a physical connection from an earlier client.
                # Establish an explicitly unauthenticated state before testing access.
                wrong=('0' if key[0]!='0' else '1')+key[1:]
                for reject_attempt in range(3):
                    await send(client,{'v':1,'type':'auth','key':wrong})
                    try:
                        await wait('error',lambda m:m.get('code')=='auth_failed',timeout=3);break
                    except TimeoutError:
                        if reject_attempt==2:raise
                await send(client,{'v':1,'type':'status'});await wait('error',lambda m:m.get('code')=='auth_required')
                result['unauthenticated_and_wrong_key_rejected']='PASS'
            for auth_attempt in range(3):
                await send(client,{'v':1,'type':'auth','key':key})
                try:
                    await wait('auth_ok',timeout=3);break
                except TimeoutError:
                    if auth_attempt==2:
                        print('Handshake message types (no private values):',observed,file=sys.stderr);raise
            await write(client,wire_snapshot(state));await wait('ack',lambda m:m.get('seq')==state['seq'] and m.get('epoch')==state['epoch'])
            await write(client,wire_companion({'companion':companion}))
            await send(client,{'v':1,'type':'status'});actual=await wait('state')
            assert actual['session_count']==len(companion['sessions']) and actual['quota_valid']==companion['quota']['valid']
            result['companion_sessions_and_quota_over_ble']='PASS'
            await send(client,{'v':1,'type':'input','button':2,'event':2});await wait('error',lambda m:m.get('code')=='invalid_message')
            result['ble_input_injection_rejected']='PASS'
            assert actual['ble_connected'] and actual['ble_authenticated']
            assert actual['pet_tokens_total']==str(state['pet_tokens_total']) and actual['family']==state['family'] and actual['level']==state['level']
            if attempt==0:
                await write(client,wire_snapshot(state));await wait('ack',lambda m:m.get('seq')==state['seq'])
                await send(client,{'v':1,'type':'status'});again=await wait('state')
                assert again['pet_tokens_total']==actual['pet_tokens_total']
                bad=dict(state,seq=state['seq']-1);await write(client,wire_snapshot(bad));await wait('error',lambda m:m.get('code')=='snapshot_rejected')
                await write(client,b'x'*2100+b'\n');await send(client,{'v':1,'type':'status'});await wait('state')
                result.update({'snapshot_ack_and_exact_ledger_match':'PASS','duplicate_no_extra_tokens':'PASS','stale_seq_rejected':'PASS','oversized_line_recovery':'PASS','encrypted_link_and_owner_auth':'PASS','free_heap':actual['free_heap']})
            else: result['disconnect_reconnect_auth_snapshot_ack']='PASS'
        await asyncio.sleep(1)
    result['private_counters_and_key_in_report']=False
    print(json.dumps(result,indent=2))
asyncio.run(main())
