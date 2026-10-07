import os,unittest
from unittest.mock import patch
from adapter import AdapterError
from gateway_adapter import GatewayRPC,GatewayModelAdapter,GatewayWorkerAdapter,terminal_text

def response(text):return {'status':'ok','result':{'payloads':[{'text':text}],'meta':{}}}
class GatewayTests(unittest.TestCase):
    def test_raw_model_no_bootstrap_or_history(self):
        calls=[]
        def call(m,p,f):calls.append((m,p,f));return response('answer')
        a=GatewayModelAdapter('openai-pool/gpt-6-astra',rpc=GatewayRPC(call));self.assertEqual(a.generate({'message':'synthetic'}),'answer');m,p,f=calls[0];self.assertEqual(m,'agent');self.assertTrue(p['modelRun']);self.assertEqual(p['promptMode'],'none');self.assertNotIn('sessionKey',p);self.assertFalse(p['deliver']);self.assertTrue(f)
    def test_exec_attribution_guard_not_removed(self):
        with patch.dict(os.environ,{'OPENCLAW_SHELL':'exec'}),patch('gateway_adapter.subprocess.run') as run:
            with self.assertRaisesRegex(AdapterError,'attribution'):GatewayRPC().call('agent',{})
            run.assert_not_called();self.assertEqual(os.environ['OPENCLAW_SHELL'],'exec')
    def test_worker_strict_steer_contract(self):
        calls=[];handles=[]
        def call(m,p,f):
            calls.append((m,p))
            if m=='sessions.create':return {'ok':True,'key':p['key']}
            if m=='agent':return response('{"text":"Original worker text","applied_revision":0}')
            if m=='tools.invoke':return {'ok':True,'output':{'status':'accepted','targetDisposition':'steered','runId':'receipt','sessionKey':p['args']['sessionKey']}}
            raise AssertionError(m)
        a=GatewayWorkerAdapter('openai-pool/gpt-6-astra',rpc=GatewayRPC(call));r=a.generate_task({'current':{'body':'synthetic'}},'test-review-task',handles.append);self.assertEqual(r['text'],'Original worker text');ack=a.steer(handles[0],'Shorter',1);self.assertEqual(ack['status'],'accepted_not_confirmed');self.assertTrue(all(m!='chat.send' for m,p in calls));self.assertEqual(calls[-1][1]['args']['mode'],'steer');self.assertEqual(calls[2][1]['bootstrapContextMode'],'lightweight');self.assertIn('wire_context',handles[0])
    def test_steer_denial_never_falls_back(self):
        calls=[]
        def call(m,p,f):calls.append(m);return {'ok':False,'error':{'type':'not_found'}}
        a=GatewayWorkerAdapter('openai-pool/gpt-6-astra',rpc=GatewayRPC(call))
        with self.assertRaises(AdapterError):a.steer({'task':'t','controller_key':'c','session_key':'s'},'x',1)
        self.assertEqual(calls,['tools.invoke'])
    def test_error_envelopes_are_not_replies(self):
        for e in [{'status':'accepted'},response(''),{'status':'ok','result':{'payloads':[{'text':'bad','isError':True}]}}]:
            with self.assertRaises(AdapterError):terminal_text(e)
