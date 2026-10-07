import json,tempfile,unittest
from pathlib import Path
from core import Store,pack,uid
from adapter import AdapterError
from gateway_adapter import GatewayRPC,GatewayWorkerAdapter
from memory_tool import MemoryTools
from memory_extractor import ModelMemoryExtractor

def result(obj):return {'status':'ok','result':{'payloads':[{'text':pack(obj)}],'meta':{}}}
class MemoryBridgeTests(unittest.TestCase):
    def test_worker_selected_real_write_and_read_in_same_session_transport_double(self):
        with tempfile.TemporaryDirectory() as root:
            identifier=uid();path=identifier+'.md';markdown=pack({'id':identifier,'title':'Worker-created synthesis'})+'\n\nSpaced practice and recall form a useful study plan.\n';calls=[];inputs=[];events=[];handles=[]
            def rpc(method,params,final):
                calls.append((method,params))
                if method=='sessions.create':return {'ok':True,'key':params['key']}
                if method=='chat.history':return {'messages':[]}
                if method!='agent':raise AssertionError(method)
                wire=json.loads(params['message']);inputs.append(wire)
                if len(inputs)==1:
                    self.assertIn('memory_tools',wire)
                    return result({'memory_call':{'tool':'memory.write','arguments':{'path':path,'markdown':markdown,'expected_sha256':None}}})
                if len(inputs)==2:
                    receipt=wire['application_tool_result']['result'];self.assertTrue(receipt['ok']);self.assertTrue(receipt['indexed']);self.assertTrue((Path(root)/'memory'/path).exists())
                    return result({'memory_call':{'tool':'memory.read','arguments':{'path':path}}})
                read=wire['application_tool_result']['result'];self.assertTrue(read['ok']);self.assertIn('Spaced practice and recall',read['markdown']);return result({'text':'The memory file was written and read back.','applied_revision':0})
            adapter=GatewayWorkerAdapter('test/model',rpc=GatewayRPC(rpc),memory_tool=MemoryTools(root));answer=adapter.generate_task({'current':{'body':'Retain this synthesis'}},uid(),lambda h:handles.append(json.loads(pack(h))),events.append)
            self.assertIn('written and read back',answer['text']);keys={p['sessionKey'] for m,p in calls if m=='agent'};self.assertEqual(len(keys),1);self.assertEqual(len([m for m,p in calls if m=='sessions.create']),2);self.assertEqual([e['text'] for e in events],['memory.write succeeded','memory.read succeeded']);self.assertEqual([h['input_sequence'] for h in handles if 'input_sequence' in h],[0,1,2]);self.assertTrue(all(len(pack(x).encode())<=26000 for x in inputs));s=Store(root);self.assertEqual(s.search_memory(query='Spaced')[0]['id'],identifier);s.db.close()
    def test_no_exposed_write_capability_no_operation(self):
        def rpc(m,p,f):
            if m=='sessions.create':return {'ok':True,'key':p['key']}
            return result({'memory_call':{'tool':'memory.write','arguments':{}}})
        adapter=GatewayWorkerAdapter('test/model',rpc=GatewayRPC(rpc))
        with self.assertRaisesRegex(AdapterError,'without an exposed'):adapter.generate_task({},uid(),lambda h:None)
    def test_stale_extractor_cannot_overwrite_intervening_worker_edit(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);t=s.topic('Preferences');first=s.add('user','I prefer concise answers.',t)
            def fact(source,value,evidence,replaces=None):return {'key':'reply.length','title':'Answer style','value':value,'evidence':evidence,'source_id':source,'replaces_id':replaces,'knowledge_type':'user_preference','attribution':'user','epistemic_status':'user_stated'}
            class Initial:
                def generate(self,c):return pack({'facts':[fact(first,'Prefers concise answers.','I prefer concise answers.')]})
            note=ModelMemoryExtractor(Initial()).extract(s,first)[0];second=s.add('user','Actually, I prefer detailed answers.',t);service=MemoryTools(root);path=s.get_memory(note)['path']
            class Delayed:
                def generate(self,c):
                    current=service({'tool':'memory.read','arguments':{'path':path}})
                    edited=current['markdown'].replace('Prefers concise answers.','Prefers concise answers. Worker-added context.')
                    reply=service({'tool':'memory.write','arguments':{'path':path,'markdown':edited,'expected_sha256':current['sha256']}})
                    if not reply['ok']:raise AssertionError(reply)
                    return pack({'facts':[fact(second,'Prefers detailed answers.','I prefer detailed answers.',note)]})
            with self.assertRaises(AdapterError):ModelMemoryExtractor(Delayed()).extract(s,second)
            self.assertIn('Worker-added context',s.get_memory(note)['body']);self.assertNotIn('Prefers detailed',s.get_memory(note)['body']);self.assertEqual(len(s.rows('SELECT * FROM messages')),2);s.db.close()
