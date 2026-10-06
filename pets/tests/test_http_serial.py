import json
import tempfile
import unittest
from pathlib import Path
import threading
from http.server import ThreadingHTTPServer
from urllib.request import Request, build_opener, ProxyHandler
urlopen = build_opener(ProxyHandler({})).open
from urllib.error import HTTPError
import os
import pty
from token_pet.app import Application,handler_for
from token_pet.serial_link import SerialLink,wire_snapshot
class WebTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.app=Application(self.temp.name,[],usb=False,account=False)
        self.server=ThreadingHTTPServer(('127.0.0.1',0),handler_for(self.app))
        self.thread=threading.Thread(target=self.server.serve_forever);self.thread.start()
        self.base=f'http://127.0.0.1:{self.server.server_port}'
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join();self.app.ledger.close();self.temp.cleanup()
    def test_routes_decimal_precision_config_and_csrf(self):
        state=json.load(urlopen(self.base+'/api/state'));self.assertEqual(state['pet_tokens_total'],'0')
        self.assertEqual(len(json.load(urlopen(self.base+'/api/catalogue'))['families']),6)
        req=Request(self.base+'/api/config',data=b'{"family":1}',headers={'Content-Type':'application/json'})
        with self.assertRaises(HTTPError) as e:urlopen(req)
        self.assertEqual(e.exception.code,403);e.exception.close()
        req.add_header('X-Pet-CSRF',state['csrf']); req.add_header('Origin','http://evil.example')
        with self.assertRaises(HTTPError) as e:urlopen(req)
        self.assertEqual(e.exception.code,403);e.exception.close()
        req.add_header('Origin',self.base)
        with self.assertRaises(HTTPError) as e:urlopen(req)
        self.assertEqual(e.exception.code,400);e.exception.close()
        req=Request(self.base+'/api/adopt',data=b'{"family":1}',headers={'Content-Type':'application/json','X-Pet-CSRF':state['csrf'],'Origin':self.base})
        r=json.load(urlopen(req));self.assertEqual(r['species_id'],172);self.assertTrue(r['adopted'])
        req=Request(self.base+'/api/adopt',data=b'{"family":0}',headers={'Content-Type':'application/json','X-Pet-CSRF':state['csrf'],'Origin':self.base})
        with self.assertRaises(HTTPError) as e:urlopen(req)
        self.assertEqual(e.exception.code,400);e.exception.close()
        self.assertEqual(urlopen(self.base+'/assets/pokemon/25.gif').headers['Content-Type'],'image/gif')
        for path in ('/assets/pokemon/../../state.sqlite','/secrets','/assets/pokemon/999999.gif'):
            with self.assertRaises(HTTPError) as e:urlopen(self.base+path)
            self.assertEqual(e.exception.code,404);e.exception.close()
        req=Request(self.base+'/api/state',headers={'Host':'evil.example'})
        with self.assertRaises(HTTPError) as e:urlopen(req)
        self.assertEqual(e.exception.code,403);e.exception.close()
class SerialTests(unittest.TestCase):
    def test_fragmented_hello_ack_and_unrelated_firmware(self):
        master,slave=pty.openpty();path=os.ttyname(slave)
        link=SerialLink(lambda:[{'port':path}])
        s={'epoch':'a'*32,'seq':7,'date':'2026-10-06','family':0,'level':1,'progress':0,'source':'local','tokens_today':10,'pet_tokens_total':10,'food':[{'model':'gpt-6-sol','tokens':10}]}
        try:
            link.poll(s);os.write(master,b'CODO HELLO 1 240 320\n');link.poll(s);self.assertFalse(link.ready)
            os.write(master,b'{"v":1,"type":"hel');link.poll(s);self.assertFalse(link.ready)
            os.write(master,b'lo","app":"token-pet"}\n');link.poll(s);self.assertTrue(link.ready)
            sent=json.loads(os.read(master,4096).splitlines()[0]);self.assertEqual(sent['pet_tokens_total'],'10')
            os.write(master,b'{"v":1,"type":"state","adopted":true,"family":0,"session_count":3,"tokens_today":"private"}\n');link.poll(s)
            self.assertEqual(link.device_state['session_count'],3);self.assertNotIn('tokens_today',link.device_state)
            os.write(master,(json.dumps({'v':1,'type':'ack','epoch':'a'*32,'seq':6})+'\n').encode());link.poll(s)
            self.assertNotEqual(link.status['status'],'synced')
            os.write(master,(json.dumps({'v':1,'type':'ack','epoch':'a'*32,'seq':7})+'\n').encode());link.poll(s)
            self.assertEqual(link.status['status'],'synced')
            link.ack_monotonic-=20;link.poll(s);self.assertEqual(link.status['status'],'syncing')
        finally:link.close();os.close(master);os.close(slave)
    def test_no_arbitrary_or_ambiguous_port(self):
        for devices,status in (([],'disconnected'),([{},{}],'ambiguous')):
            link=SerialLink(lambda:devices);link.connect();self.assertIsNone(link.fd);self.assertEqual(link.status['status'],status)
    def test_uint64_counts_decimal_strings_and_max_food(self):
        s={'epoch':'a'*32,'seq':2,'date':'2026-10-06','family':5,'level':12,'progress':100,'source':'local','tokens_today':2**63-1,'pet_tokens_total':2**63-1,'food':[{'model':'x'*64,'tokens':2**63-1}]*20}
        decoded=json.loads(wire_snapshot(s));self.assertEqual(decoded['pet_tokens_total'],str(2**63-1));self.assertEqual(len(decoded['food']),3)
if __name__=='__main__':unittest.main()
