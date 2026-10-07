import json,tempfile,unittest
from core import Store,pack
from server import App
from adapter import AdapterError,DisabledAdapter
from memory_extractor import ModelMemoryExtractor
from orchestrator import Orchestrator
class Fake:
    name='TEST DOUBLE'
    def __init__(self,value):self.value=value;self.calls=[]
    def generate(self,c):self.calls.append(c);return self.value

def choice(t,action='clarify',reply='Which topic?',instruction=''):return pack(dict(action=action,topic_id=t,new_topic='',instruction=instruction,reply=reply,task_id=None))
class ReviewTests(unittest.TestCase):
    def test_escalation_resolves_once_before_dispatch(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);t=s.topic('Synthetic');m=s.add('user','this one',t);strong=Fake(choice(t,'delegate','','Summarize topic'));o=Orchestrator(Fake(choice(t)),Fake('not run'),strong);c,d,topic=o.route(s,'this one',None,m,'none');self.assertEqual(d['action'],'delegate');self.assertEqual(len(strong.calls),1);self.assertLessEqual(len(pack(strong.calls[0]).encode()),12000);self.assertFalse(s.rows('SELECT * FROM tasks'));s.db.close()
    def test_unresolved_asks_without_task_or_steering(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);t=s.topic('Synthetic');m=s.add('user','change that',t);strong=Fake(choice(t));o=Orchestrator(Fake(choice(t)),Fake('never called'),strong);_,d,_=o.route(s,'change that',None,m,'none');self.assertEqual(d['action'],'reply');self.assertEqual(d['reply'],'Which topic?');self.assertEqual(len(strong.calls),1);self.assertFalse(s.rows('SELECT * FROM tasks'));self.assertFalse(s.rows('SELECT * FROM amendments'));s.db.close()
    def test_background_result_does_not_change_active_topic(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);a=s.topic('A');b=s.topic('B');old=s.add('user','A',a);s.add('user','B',b);s.add('assistant','Late A result',a,reply_to=old);self.assertEqual(s.route('continue')[0],b);s.db.close()
    def test_semantic_provenance_correction_forget(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);t=s.topic('Preferences');m=s.add('user','For discussions, please keep answers concise.',t);fact={'key':'reply.length','title':'Response style','value':'Prefers concise answers','evidence':'please keep answers concise','source_id':m,'replaces_id':None,'knowledge_type':'user_preference','attribution':'user','epistemic_status':'user_stated'};model=Fake(pack({'facts':[fact]}));extractor=ModelMemoryExtractor(model);i=extractor.extract(s,m)[0];meta=json.loads(next(s.memory.rglob(i+'.md')).read_text().split('\n\n')[0]);self.assertEqual(meta['sources'],[m]);self.assertEqual(meta['evidence'],fact['evidence']);m2=s.add('user','Actually, explain in depth from now on.',t);fact.update(value='Prefers depth',evidence='explain in depth from now on',source_id=m2,replaces_id=i);model.value=pack({'facts':[fact]});self.assertEqual(extractor.extract(s,m2),[i]);before=s.rows('SELECT * FROM messages');s.forget_memory(i);s.rebuild();self.assertFalse(s.search_memory(t));self.assertEqual(before,s.rows('SELECT * FROM messages'));s.db.close()
    def test_hallucinated_and_tentative_provenance_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);t=s.topic('Test');m=s.add('user','Maybe I prefer tea.',t);f={'key':'drink','title':'Drink','value':'Tea','evidence':'Maybe I prefer tea','source_id':m,'replaces_id':None,'knowledge_type':'user_preference','attribution':'user','epistemic_status':'user_stated'}
            with self.assertRaises(AdapterError):ModelMemoryExtractor(Fake(pack({'facts':[f]}))).extract(s,m)
            f.update(evidence='I prefer coffee',source_id='invented')
            with self.assertRaises(AdapterError):ModelMemoryExtractor(Fake(pack({'facts':[f]}))).extract(s,m)
            self.assertFalse(s.search_memory(t));s.db.close()
    def test_forget_never_replays_processed_history(self):
        with tempfile.TemporaryDirectory() as root:
            app=App(root,Orchestrator(DisabledAdapter(),DisabledAdapter()));t=app.store.topic('Example');m=app.store.add('user','My timezone is JST.',t);app.extract(m);i=app.store.search_memory(t)[0]['id'];before=app.store.rows('SELECT * FROM messages');app.store.forget_memory(i);app.extract(m);app.store.rebuild();self.assertFalse(app.store.search_memory(t));self.assertEqual(before,app.store.rows('SELECT * FROM messages'));app.close()
    def test_terminal_before_steering_receipt_reconciles_once(self):
        with tempfile.TemporaryDirectory() as root:
            class Worker:
                name='TEST'
                def steer(self,handle,instruction,revision):
                    app.complete(app.store,mid,'task',{'text':'Revised answer','applied_revision':revision})
                    self_before=app.store.rows('SELECT status FROM task_results')[0]['status']
                    if self_before!='stale':raise AssertionError('Admission race must initially be stale')
                    return {'status':'accepted_not_confirmed','revision':revision}
            app=App(root,Orchestrator(DisabledAdapter(),Worker()));s=app.store;t=s.topic('Synthetic');mid=s.add('user','Original',t);follow=s.add('user','Revise',t)
            s.db.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?)',('task',mid,'{}','{}','test','working'))
            s.db.executemany('INSERT INTO turns VALUES (?,?,?,NULL)',[(mid,'{}','pending'),(follow,'{}','pending')]);s.db.execute('INSERT INTO amendments VALUES (?,?,?,?,?)',('amend','task',follow,'Revise','pending_unsupported'));s.db.execute('INSERT INTO steering_receipts VALUES (?,?,NULL)',('amend',1));s.db.execute('INSERT INTO harness_tasks VALUES (?,?)',('task','{}'));s.db.commit()
            app.submit_steer(s,'task','amend',follow,'Revise');self.assertEqual(s.rows('SELECT status FROM amendments')[0]['status'],'applied_confirmed_by_output');self.assertEqual(s.rows('SELECT status FROM task_results')[0]['status'],'current');app.complete(s,mid,'task',{'text':'Revised answer','applied_revision':1});self.assertEqual(len(s.rows("SELECT * FROM messages WHERE role='assistant'")),1);self.assertEqual(len(s.rows('SELECT * FROM tasks')),1);app.close()
