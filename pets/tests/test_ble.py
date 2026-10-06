import asyncio
import json
import unittest
from token_pet.ble_link import NotificationParser,BLELink
class BLETests(unittest.TestCase):
    def test_fragmented_notifications_and_oversized_input(self):
        parser=NotificationParser();packet=b'{"v":1,"type":"ack","seq":42}\n'
        for byte in packet[:-1]:self.assertEqual(parser.feed(bytes([byte])),[])
        self.assertEqual(parser.feed(packet[-1:])[0]['seq'],42)
        self.assertEqual(parser.feed(b'x'*9000),[])
        self.assertEqual(parser.feed(b'\n'+packet)[0]['seq'],42)
        self.assertEqual(parser.feed(b'{"v":2,"type":"ack"}\nno json\n'),[])
    def test_twenty_byte_writes_are_complete_and_require_response(self):
        class Client:
            def __init__(self):self.parts=[]
            async def write_gatt_char(self,uuid,data,response):self.parts.append(data);assert response
        client=Client();link=BLELink('a'*64,lambda:{},lambda:False,None)
        payload=b'123456789'*70
        asyncio.run(link.write(client,payload))
        self.assertEqual(b''.join(client.parts),payload);self.assertTrue(all(len(x)<=20 for x in client.parts))
if __name__=='__main__':unittest.main()

class AuthenticationRetryTests(unittest.IsolatedAsyncioTestCase):
    async def test_lost_first_response_retries_same_idempotent_auth(self):
        import asyncio,threading
        from token_pet.ble_link import BLELink
        authorized=asyncio.Event()
        class Client:
            def __init__(self):self.pending=bytearray();self.requests=0
            async def write_gatt_char(self,char,data,response):
                self.pending.extend(data)
                if b'\n' in self.pending:
                    self.requests+=1;self.pending.clear()
                    if self.requests==2:authorized.set()
        client=Client();link=BLELink('a'*64,lambda:None,lambda:False,threading.Event())
        await link.authenticate(client,authorized,timeout=.01)
        self.assertEqual(client.requests,2)
