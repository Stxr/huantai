#!/usr/bin/env python3
"""Exercise only the connected Token Pet firmware with synthetic test meals."""
import argparse
import json
import os
from pathlib import Path
import select
import sys
import time
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'host'));sys.path.insert(0,str(ROOT/'scripts'))
from token_pet.serial_link import SerialLink
from probe_hardware import discover
class Device:
    def __init__(self):
        self.link=SerialLink(discover);self.link.connect()
        if self.link.fd is None:raise RuntimeError('Exactly one accessible Espressif device required')
        self.pending=bytearray();self.panics=0
    def send(self,message):
        self.send_bytes((json.dumps(message,separators=(',',':'))+'\n').encode())
    def send_bytes(self,data):
        view=memoryview(data);deadline=time.monotonic()+2
        while view:
            if time.monotonic()>deadline:raise TimeoutError('Write timeout')
            if select.select([],[self.link.fd],[],.1)[1]:view=view[os.write(self.link.fd,view):]
    def messages(self,timeout):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            while b'\n' in self.pending:
                line,_,rest=self.pending.partition(b'\n');self.pending[:]=rest
                if b'Guru Meditation' in line or b'panic' in line or b'assert failed' in line:self.panics+=1
                try:m=json.loads(line)
                except (ValueError,UnicodeError):continue
                if isinstance(m,dict) and m.get('v')==1:yield m
            if select.select([self.link.fd],[],[],.1)[0]:
                data=os.read(self.link.fd,4096)
                if data:self.pending.extend(data)
    def wait(self,kind,predicate=lambda m:True,timeout=6):
        for message in self.messages(timeout):
            if message.get('type')==kind and predicate(message):return message
        raise TimeoutError('No matching '+kind)
    def state(self):self.send({'v':1,'type':'status'});return self.wait('state')
    def capture(self,path):
        from PIL import Image
        self.send({'v':1,'type':'capture'});begin=self.wait('capture_begin')
        width,height=begin['width'],begin['height'];pixels=[0]*(width*height);seen=set();rows=0
        for msg in self.messages(20):
            if msg.get('type')=='capture_end':break
            if msg.get('type')!='capture_row':continue
            y,x=msg['y'],msg['x'];encoded=msg['pixels'];assert 0<=y<height and 0<=x<width and len(encoded)%6==0
            row=[]
            for i in range(0,len(encoded),6):row.extend([int(encoded[i:i+4],16)]*int(encoded[i+4:i+6],16))
            assert len(row)==msg['width'] and x+len(row)<=width
            for dx,value in enumerate(row):pixels[y*width+x+dx]=value;seen.add((x+dx,y))
            rows+=1
        assert len(seen)==width*height, 'Incomplete captured frame'
        rgb=[((p>>11)*255//31,((p>>5)&63)*255//63,(p&31)*255//31) for p in pixels]
        im=Image.new('RGB',(width,height));im.putdata(rgb);im.save(path)
        return {'width':width,'height':height,'rows':rows,'page':begin['page'],'all_pixels_received':True}
    def close(self):self.link.close()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--capture',type=Path);parser.add_argument('--state-only',action='store_true');args=parser.parse_args()
    d=Device();result={}
    try:
        result['hello']=d.wait('hello',lambda m:m.get('app')=='token-pet')
        if args.state_only:result['state']=d.state()
        else:
            mappings=[]
            for family,chain in enumerate(((4,5,6),(172,25,26),(1,2,3),(7,8,9),(147,148,149),(92,93,94))):
                epoch=f'{family+1:032x}'
                for level in range(1,13):
                    packet={'v':1,'type':'snapshot','epoch':epoch,'seq':level,'date':'2026-10-06','family':family,'level':level,'progress':25,'source':'local','tokens_today':str(level*100),'pet_tokens_total':str(level*100),'food':[{'model':'test-model','tokens':str(level*100)}]}
                    d.send(packet);d.wait('ack',lambda m:m.get('epoch')==epoch and m.get('seq')==level)
                    state=d.state();assert state['species_id']==chain[(level-1)//4] and state['level']==level and state['pet_tokens_total']==str(level*100)
                    mappings.append([family,level,state['species_id']])
                d.send(packet);d.wait('ack',lambda m:m.get('epoch')==epoch and m.get('seq')==12)
                assert d.state()['pet_tokens_total']=='1200'
                bad=dict(packet,seq=11);d.send(bad);d.wait('error',lambda m:m.get('code')=='snapshot_rejected')
                assert d.state()['seq']==12
            result['growth_mappings']=mappings;result['duplicate_and_old_seq']='PASS'
            # Oversized line followed by a valid request must recover without reset.
            d.send_bytes(b'x'*2100+b'\n');assert d.state()['seq']==12
            d.send({'v':1,'type':'snapshot','family':99});d.wait('error')
            result['malformed_and_oversized_recovery']='PASS'
            deadline=time.monotonic()+12
            while time.monotonic()<deadline:
                state=d.state()
                if state['saved']:break
                time.sleep(.3)
            assert state['saved'];result['saved_state']=state
        if args.capture:result['capture']=d.capture(args.capture)
        result['panic_lines_observed']=d.panics
        assert not d.panics
        print(json.dumps(result,indent=2))
    finally:d.close()
if __name__=='__main__':main()
