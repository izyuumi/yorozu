import threading,time,unittest,tempfile,json
from server import App
from core import pack
from orchestrator import Orchestrator
from adapter import AdapterError

def until(fn):
    end=time.time()+4
    while time.time()<end:
        if fn():return
        time.sleep(.01)
    raise AssertionError('Timed out')
def output(topic,action='delegate',task=None):return pack(dict(action=action,topic_id=topic,new_topic='',instruction='' if action=='reply' else 'Follow latest request',reply='Still here' if action=='reply' else '',task_id=task))
class AsyncTests(unittest.TestCase):
    def test_conversation_out_of_order_failure(self):
        with tempfile.TemporaryDirectory() as root:
            entered=threading.Event();release=threading.Event()
            class Sec:
                name='TEST';calls=[]
                def generate(self,c):self.calls.append(c);return output(c['candidates'][0]['id'],'reply' if c['message']=='hello' else 'delegate')
            class Worker:
                name='TEST';model='test/worker'
                def generate(self,c):
                    if c['current']['body']=='slow':entered.set();release.wait(4)
                    if c['current']['body']=='fail':raise AdapterError('synthetic failure')
                    return 'Result '+c['current']['body']
            sec=Sec();app=App(root,Orchestrator(sec,Worker()));topic=app.store.topic('Example')
            try:
                first=app.post('/api/send',{'body':'slow','topic':topic});self.assertTrue(entered.wait(2));hello=app.post('/api/send',{'body':'hello','topic':topic});fast=app.post('/api/send',{'body':'fast','topic':topic});bad=app.post('/api/send',{'body':'fail','topic':topic})
                until(lambda:any(m['reply_to']==fast['message'] for m in app.store.state()['messages']));until(lambda:any(m['reply_to']==hello['message'] for m in app.store.state()['messages']));until(lambda:any(m['id']==bad['message'] and m['status']=='error' for m in app.store.state()['messages']));self.assertFalse(any(m['reply_to']==first['message'] for m in app.store.state()['messages']));self.assertTrue(any(c['active_tasks'] for c in sec.calls));release.set();until(lambda:not app.store.rows("SELECT * FROM turns WHERE status='pending'"));self.assertEqual([m for m in app.store.state()['messages'] if m['role']=='assistant'][-1]['reply_to'],first['message'])
            finally:release.set();app.close()
    def test_same_task_steering_stale_no_duplicate(self):
        with tempfile.TemporaryDirectory() as root:
            entered=threading.Event();release=threading.Event()
            class Sec:
                name='TEST'
                def generate(self,c):return output(c['candidates'][0]['id'],'steer',c['active_tasks'][0]['id']) if c['message']=='change blue' else output(c['candidates'][0]['id'])
            class Worker:
                name='TEST';calls=0
                def generate(self,c):self.calls+=1;entered.set();release.wait(4);return 'Stale red result'
            worker=Worker();app=App(root,Orchestrator(Sec(),worker));topic=app.store.topic('Colors')
            try:
                app.post('/api/send',{'body':'make red','topic':topic});self.assertTrue(entered.wait(2));task=app.store.state()['tasks'][0]['id'];app.post('/api/send',{'body':'change blue','topic':topic});until(lambda:bool(app.store.rows('SELECT * FROM amendments')));self.assertEqual(len(app.store.state()['tasks']),1);self.assertEqual(app.store.rows('SELECT * FROM amendments')[0]['task'],task);release.set();until(lambda:bool(app.store.rows('SELECT * FROM task_results')));self.assertEqual(worker.calls,1);self.assertEqual(app.store.rows('SELECT * FROM task_results')[0]['status'],'stale');self.assertFalse(any(m['role']=='assistant' for m in app.store.state()['messages']))
            finally:release.set();app.close()
