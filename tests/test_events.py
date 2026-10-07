import tempfile,unittest,time
from worker_events import visible_events
from core import pack
from server import App
from orchestrator import Orchestrator
class EventTests(unittest.TestCase):
    def test_projection_excludes_reasoning_credentials_and_tool_data(self):
        h={'messages':[{'id':'a','role':'assistant','content':[{'type':'thinking','thinking':'HIDDEN'},{'type':'text','text':'Visible progress'},{'type':'toolCall','name':'memory.search','arguments':{'secret':'DO_NOT_EXPOSE'}},{'type':'text','text':'api_key=DO_NOT_EXPOSE'}]},{'id':'b','role':'toolResult','content':'DO_NOT_EXPOSE'},{'id':'c','role':'assistant','channel':'analysis','content':'HIDDEN'},{'role':'assistant','content':'uncommitted live token'}]}
        events=visible_events(h);self.assertEqual([e['kind'] for e in events],['message','tool_metadata','redacted']);self.assertNotIn('HIDDEN',pack(events));self.assertNotIn('DO_NOT_EXPOSE',pack(events));self.assertNotIn('uncommitted',pack(events))
    def test_event_projection_retains_order_and_source_identity(self):
        h={'messages':[{'id':'a','role':'assistant','content':'First'},{'id':'b','role':'assistant','content':'Second'}]};events=visible_events(h);self.assertEqual([e['text'] for e in events],['First','Second']);self.assertEqual(events[0]['id'],'a:0');self.assertEqual(events[0]['source'],'gateway.chat.history')
    def test_events_persist_deduplicate_and_never_flood_main(self):
        with tempfile.TemporaryDirectory() as root:
            class Sec:
                name='TEST'
                def generate(self,c):return pack({'action':'delegate','topic_id':c['candidates'][0]['id'],'new_topic':'','instruction':'Analyze','reply':'','task_id':None})
            class Worker:
                name='TEST';supports_events=True
                def generate_task(self,ctx,task,on_handle,on_event):
                    on_handle({'session_key':'synthetic'})
                    e={'id':'a:0','source_id':'a','kind':'message','text':'Genuine test-fixture progress','timestamp':1,'source':'test-double'};on_event(e);on_event(e)
                    return {'text':'Final answer','applied_revision':0}
            app=App(root,Orchestrator(Sec(),Worker()));topic=app.store.topic('Synthetic');app.post('/api/send',{'body':'Analyze this','topic':topic});end=time.time()+3
            while time.time()<end and app.store.rows("SELECT * FROM turns WHERE status='pending'"):time.sleep(.01)
            self.assertEqual(len(app.store.rows('SELECT * FROM worker_events')),1);self.assertEqual([m['body'] for m in app.store.state()['messages']],['Analyze this','Final answer']);app.close()
            from core import Store
            s=Store(root);self.assertEqual(s.rows('SELECT body FROM worker_events')[0]['body'],'Genuine test-fixture progress');s.db.close()
    def test_application_tool_requests_never_expose_raw_markdown_arguments(self):
        body=pack({'memory_call':{'tool':'memory.write','arguments':{'markdown':'SENSITIVE_ARGUMENT_BODY','path':'private-path.md'}}});events=visible_events({'messages':[{'id':'request','role':'assistant','content':body}]});self.assertEqual(events[0]['kind'],'tool_metadata');self.assertIn('memory.write',events[0]['text']);self.assertNotIn('SENSITIVE_ARGUMENT_BODY',pack(events));self.assertNotIn('private-path',pack(events))
