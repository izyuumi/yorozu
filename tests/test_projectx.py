import json,tempfile,unittest,time,threading
from pathlib import Path
from core import Store,pack,BUDGET
from adapter import OpenClawAdapter,AdapterError,DisabledAdapter
from server import App,Handler
from orchestrator import Orchestrator
from memory_tool import invoke
class Fake:
    name='TEST DOUBLE';model='test/model'
    def __init__(self,response):self.response=response;self.calls=[]
    def generate(self,context):self.calls.append(context);return self.response
def wait(app):
    end=time.time()+4
    while time.time()<end:
        if not app.store.rows("SELECT message FROM turns WHERE status='pending'"):return
        time.sleep(.01)
    raise AssertionError('Task timeout')
class Tests(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.s=Store(self.tmp.name);self.a=self.s.topic('Garden');self.b=self.s.topic('Coding')
    def tearDown(self):self.s.db.close();self.tmp.cleanup()
    def test_persistence_originals(self):
        m=self.s.add('user','Original',self.a);self.s.correct(m,self.b);self.s.db.close();self.s=Store(self.tmp.name)
        self.assertEqual(self.s.state()['messages'][0]['body'],'Original');self.assertEqual(self.s.state()['messages'][0]['topic'],self.b)
    def test_conversation_isolation_and_relevant_memory_budget(self):
        self.s.add('user','SECRET OTHER TOPIC',self.b)
        for i in range(40):self.s.add('user','garden '+('花'*900),self.a)
        self.s.write_memory(self.b,'Other','PRIVATE MEMORY');m=self.s.add('user','Garden?',self.a);ctx=pack(self.s.context(m))
        self.assertLessEqual(len(ctx.encode()),BUDGET);self.assertNotIn('SECRET',ctx);self.assertNotIn('PRIVATE MEMORY',ctx);self.assertLess(len(json.loads(ctx)['history']),40)
    def test_correct_linked_exchange(self):
        m=self.s.add('user','Original',self.a);r=self.s.add('assistant','Answer',self.a,reply_to=m);self.s.correct(r,self.b)
        self.assertTrue(all(x['topic']==self.b for x in self.s.state()['messages']));self.assertEqual(len(self.s.rows('SELECT * FROM corrections')),2)
    def test_memory_rebuild_tool(self):
        i=self.s.write_memory(self.a,'Keep','water weekly');self.s.db.execute('DELETE FROM memory_index');self.s.db.commit();self.assertEqual(self.s.rebuild(),1)
        self.assertEqual(invoke(self.s,{'tool':'memory.search','arguments':{'topic_id':self.a,'query':'weekly'}})['results'][0]['id'],i)
        with self.assertRaises(ValueError):invoke(self.s,{'tool':'memory.write'})
    def test_memory_path_safety_atomic(self):
        self.s.write_memory(self.a,'Safe','safe');(self.s.memory/'escape.md').symlink_to(Path(self.tmp.name)/'projectx.sqlite')
        with self.assertRaises(ValueError):self.s.rebuild()
        self.assertEqual(len(self.s.search_memory(self.a)),1)
        with self.assertRaises(ValueError):self.s.write_memory('../../escape','x','y')
    def test_adapter_errors(self):
        for code,out in [(1,'{}'),(0,'noise'),(0,'{"ok":false}'),(0,'{"ok":true,"status":"ok","final":""}')]:
            with self.assertRaises(AdapterError):OpenClawAdapter('test/model',lambda *a:(code,out,'private diagnostics')).generate({})
        a=OpenClawAdapter('test/model',lambda *a:(0,'{"ok":true,"status":"ok","final":"real-shaped"}',''));self.assertEqual(a.generate({}),'real-shaped')
    def test_secretary_worker_flow(self):
        sec=Fake(pack({'action':'delegate','task_id':None,'reply':'','topic_id':self.a,'new_topic':'','instruction':'Answer garden request'}));worker=Fake('Unmodified worker response');app=App(self.tmp.name,Orchestrator(sec,worker));app.post('/api/send',{'body':'How to water?','topic':self.a});wait(app)
        self.assertEqual(len(sec.calls),1);self.assertEqual(len(worker.calls),1);self.assertEqual(worker.calls[0]['delegation'],'Answer garden request');self.assertEqual(app.store.state()['messages'][-1]['body'],'Unmodified worker response');self.assertEqual(app.store.rows('SELECT * FROM tasks')[0]['status'],'done');app.close()
    def test_invalid_routing_blocks_worker(self):
        worker=Fake('not called');app=App(self.tmp.name,Orchestrator(Fake('{"topic_id":"invented"}'),worker));app.post('/api/send',{'body':'Hello'});wait(app);self.assertFalse(worker.calls);self.assertEqual(len(app.store.state()['messages']),1);self.assertEqual(app.store.state()['messages'][0]['status'],'error');app.close()
    def test_offline_not_fake(self):
        app=App(self.tmp.name,Orchestrator(DisabledAdapter(),DisabledAdapter()));app.post('/api/send',{'body':'Hello'});wait(app);self.assertEqual(len(app.store.state()['messages']),1);self.assertIn('Live model is off',app.store.state()['messages'][0]['error']);app.close()
    def test_latest_topic(self):
        self.s.add('user','Code',self.b);self.assertEqual(self.s.route('ambiguous')[0],self.b)
    def test_origin_guard(self):
        from types import SimpleNamespace
        h=object.__new__(Handler);h.server=SimpleNamespace(expected_host='127.0.0.1:8765');h.headers={'Host':'127.0.0.1:8765','Origin':'http://evil.test','Content-Type':'application/json','X-ProjectX':'1'};self.assertFalse(h.allowed(True));h.headers['Origin']='http://127.0.0.1:8765';self.assertTrue(h.allowed(True));h.headers['Host']='evil.test';self.assertFalse(h.allowed())
if __name__=='__main__':unittest.main()
