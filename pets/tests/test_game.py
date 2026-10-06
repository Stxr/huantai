import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from token_pet.app import Application
from token_pet.ledger import Ledger
from token_pet.huantai import HuantaiBridge, display_text
from token_pet.serial_link import wire_companion

class GameTests(unittest.TestCase):
    def test_adoption_lock_survives_restart_and_preserves_intake(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'pet.sqlite';ledger=Ledger(path)
            self.assertFalse(ledger.snapshot()['adopted'])
            with ledger.db: ledger.db.execute("INSERT INTO meals VALUES('legacy','2026-10-06','test-model',321)")
            ledger.adopt(3);ledger.adopt(3)
            with self.assertRaises(ValueError):ledger.adopt(2)
            with self.assertRaises(ValueError):ledger.configure(family=2)
            ledger.close();ledger=Ledger(path)
            self.assertEqual(ledger.snapshot()['pet_tokens_total'],321)
            self.assertEqual(ledger.snapshot()['family'],3);self.assertTrue(ledger.snapshot()['adopted']);ledger.close()

    def test_display_unicode_and_wire_bound(self):
        self.assertEqual(display_text('中文🐱\nABC'),'中文??ABC')
        value={'available':True,'sessions':[{'handle':'a'*16,'title':'中'*24,'source':'Codex','openable':True}]*3,'quota':{'valid':True,'remaining':1000,'reset_at':200,'reset_text':'10-10 12:00','reference':0,'today':-1000,'live':True},'now':100}
        wire=wire_companion({'companion':value});self.assertLessEqual(len(wire),2048)
        self.assertEqual(json.loads(wire)['reset_after'],100)

    def test_huantai_sort_completed_and_stale_open(self):
        rows=[{'id':str(i),'title':'会话'+str(i),'source':'Codex','openURL':'codex://threads/x','lastAIReplyAt':f'2026-10-06T0{i}:00:00Z','isCompleted':i==4} for i in range(5)]
        payload={'snapshot':{'sessions':rows,'usage':{}},'usageProjection':{}}
        bridge=HuantaiBridge(lambda *args,**kwargs:io.BytesIO(json.dumps(payload).encode()))
        bridge.refresh();state=bridge.snapshot()
        self.assertTrue(state['available']);self.assertEqual([r['title'] for r in state['sessions']],['会话3','会话2','会话1'])
        with self.assertRaises(ValueError):bridge.open('forged')
        bridge.last_read-=20
        with self.assertRaises(ValueError):bridge.open(state['sessions'][0]['handle'])
        self.assertFalse(bridge.snapshot()['available'])

    def test_replayed_hardware_action_opens_once(self):
        with tempfile.TemporaryDirectory() as directory:
            app=Application(directory,[],usb=False,account=False);app.ledger.adopt(0)
            calls=[];app.companion.open=lambda handle:calls.append(handle)
            message={'v':1,'type':'action','action':'open','epoch':app.ledger.snapshot()['epoch'],'request':'a'*32,'handle':'b'*16}
            thread=threading.Thread(target=app.action_loop);thread.start()
            app.enqueue_action(message,'usb');app.enqueue_action(message,'usb')
            deadline=time.monotonic()+2
            while app.serial.outbox.qsize()<2 and time.monotonic()<deadline:time.sleep(.01)
            app.stop.set();thread.join();self.assertEqual(calls,['b'*16]);self.assertEqual(app.serial.outbox.qsize(),2)
            app.ledger.close()
