import json
import tempfile
import unittest
from pathlib import Path
from datetime import datetime, timezone, timedelta
from token_pet.ledger import Ledger

NOW = datetime(2026,10,6,8,tzinfo=timezone.utc)
def event(total, last=10, at=NOW, model=None):
    if model:
        return {'type':'turn_context','payload':{'model':model}}
    return {'type':'event_msg','timestamp':at.isoformat(),'payload':{'type':'token_count','info':{
        'total_token_usage':{'total_tokens':total,'input_tokens':total-10,'output_tokens':10,'cached_input_tokens':20,'reasoning_output_tokens':5},
        'last_token_usage':{'total_tokens':last}}}}
def append(path, *items):
    with path.open('ab') as f:
        for item in items: f.write(json.dumps(item).encode()+b'\n')
class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.ledger=Ledger(self.root/'state.sqlite', now=NOW);self.ledger.adopt(0)
        self.path=self.root/'rollout-11111111-1111-1111-1111-111111111111.jsonl'
    def tearDown(self): self.ledger.close(); self.temp.cleanup()
    def snapshot(self): return self.ledger.snapshot(NOW)
    def test_baseline_duplicates_and_cache_subsets(self):
        append(self.path,event(0,model='gpt-6.1-sol'),event(100))
        self.ledger.initialize_baselines([self.path])
        self.assertEqual(self.ledger.scan_file(self.path),0)
        append(self.path,event(140,40),event(140,40))
        self.assertEqual(self.ledger.scan_file(self.path),40)
        self.assertEqual(self.ledger.scan_file(self.path),0)
        self.assertEqual(self.snapshot()['food'],[{'model':'gpt-6.1-sol','tokens':40}])
        self.assertEqual(self.snapshot()['pet_tokens_total'],40)
    def test_partial_line_waits_then_counts_once(self):
        append(self.path,event(100)); self.ledger.initialize_baselines([self.path])
        raw=json.dumps(event(130,30)).encode()
        with self.path.open('ab') as f:f.write(raw[:30])
        self.assertEqual(self.ledger.scan_file(self.path),0)
        with self.path.open('ab') as f:f.write(raw[30:]+b'\n')
        self.assertEqual(self.ledger.scan_file(self.path),30)
    def test_new_file_only_last_increment_and_pre_adoption_ignored(self):
        self.ledger.initialize_baselines([])
        append(self.path,event(80,80,at=NOW-timedelta(days=1)),event(100,20))
        self.assertEqual(self.ledger.scan_file(self.path),20)
    def test_copied_fork_and_archived_move(self):
        self.ledger.initialize_baselines([])
        append(self.path,event(100,model='gpt-6-sol'),event(100,20))
        self.assertEqual(self.ledger.scan_file(self.path),20)
        fork=self.root/'fork.jsonl';fork.write_bytes(self.path.read_bytes())
        self.assertEqual(self.ledger.scan_file(fork),0)
        archived=self.root/'archive';archived.mkdir();moved=archived/self.path.name;self.path.rename(moved)
        append(moved,event(140,40,at=NOW+timedelta(seconds=1)))
        self.assertEqual(self.ledger.scan_file(moved),40)
        self.assertEqual(self.snapshot()['pet_tokens_total'],60)
    def test_counter_reset_and_file_replacement(self):
        append(self.path,event(100)); self.ledger.initialize_baselines([self.path])
        append(self.path,event(10),event(25,15,at=NOW+timedelta(seconds=1)))
        self.assertEqual(self.ledger.scan_file(self.path),15)
        replacement=self.root/'new';replacement.write_text(json.dumps(event(10))+'\n');replacement.replace(self.path)
        self.assertEqual(self.ledger.scan_file(self.path),0) # copied event seen
        append(self.path,event(30,20,at=NOW+timedelta(seconds=2)))
        self.assertEqual(self.ledger.scan_file(self.path),20)
    def test_account_baseline_delta_null_reset_and_source_switch(self):
        def payload(n):return {'summary':{'lifetimeTokens':n},'dailyUsageBuckets':[{'startDate':'2026-10-05'}]}
        self.ledger.configure(source='account')
        self.assertEqual(self.ledger.update_account(payload(None),NOW),0)
        self.assertEqual(self.ledger.update_account(payload(1000),NOW),0)
        self.assertEqual(self.ledger.update_account(payload(1100),NOW),100)
        self.assertEqual(self.ledger.update_account(payload(1100),NOW),0)
        self.assertEqual(self.ledger.update_account(payload(50),NOW),0)
        self.assertEqual(self.ledger.update_account(payload(60),NOW),10)
        self.ledger.configure(source='local');self.ledger.update_account(payload(500),NOW)
        self.ledger.configure(source='account');self.assertEqual(self.ledger.update_account(payload(1000),NOW),0)
        self.assertEqual(self.snapshot()['pet_tokens_total'],110)
        self.assertEqual(self.snapshot()['account_latest_date'],'2026-10-05')
    def test_local_switch_rebaseline_does_not_replay_offline_source(self):
        append(self.path,event(100));self.ledger.initialize_baselines([self.path])
        self.ledger.configure(source='account');append(self.path,event(200,100));self.ledger.scan_file(self.path)
        self.ledger.configure(source='local');append(self.path,event(220,20));self.ledger.initialize_baselines([self.path])
        append(self.path,event(240,20,at=NOW+timedelta(seconds=1)))
        self.assertEqual(self.ledger.scan_file(self.path),20)
        self.assertEqual(self.snapshot()['pet_tokens_total'],20)
    def test_midnight_seq_persistence_and_twelve_levels(self):
        self.ledger.configure(thresholds=list(range(12)))
        self.ledger.initialize_baselines([]);append(self.path,event(11,11));self.ledger.scan_file(self.path)
        s=self.snapshot();self.assertEqual(s['level'],12)
        tomorrow=self.ledger.snapshot(datetime(2026,10,6,16,tzinfo=timezone.utc))
        self.assertEqual(tomorrow['tokens_today'],0);self.assertGreater(tomorrow['seq'],s['seq'])
        self.ledger.configure(thresholds=[x*100 for x in range(12)])
        self.assertEqual(self.snapshot()['level'],12)
        epoch=s['epoch'];self.ledger.close();self.ledger=Ledger(self.root/'state.sqlite')
        self.assertEqual(self.snapshot()['epoch'],epoch);self.assertEqual(self.snapshot()['pet_tokens_total'],11)
    def test_invalid_config_rolls_back_and_models_are_sanitized(self):
        for change in ({'family':6},{'source':'unknown'},{'thresholds':[0]*12},{'thresholds':list(range(11))}):
            with self.assertRaises(ValueError):self.ledger.configure(**change)
        with self.assertRaises(ValueError):self.ledger.configure(family=1,source='unknown')
        self.assertEqual(self.snapshot()['family'],0)
        self.ledger.initialize_baselines([]);append(self.path,event(0,model='private text'),event(10))
        self.ledger.scan_file(self.path);self.assertEqual(self.snapshot()['food'][0]['model'],'unknown-model')
if __name__=='__main__':unittest.main()
