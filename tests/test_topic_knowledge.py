import tempfile,time,unittest
from core import Store,pack
from adapter import AdapterError
from memory_extractor import ModelMemoryExtractor
from orchestrator import Orchestrator
from server import App
class Fake:
    name='TEST DOUBLE'
    def __init__(self,value):self.value=value;self.calls=[]
    def generate(self,c):self.calls.append(c);return self.value

def proposal(mid,evidence,kind='source_claim',who='quoted_source',status='unverified',key='topic.claim',replaces=None,value=None):
    return {'key':key,'title':'Useful topic knowledge','value':value or evidence,'evidence':evidence,'source_id':mid,'replaces_id':replaces,'knowledge_type':kind,'attribution':who,'epistemic_status':status}
class TopicKnowledgeTests(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.s=Store(self.temp.name);self.t=self.s.topic('Synthetic research')
    def tearDown(self):self.s.db.close();self.temp.cleanup()
    def extract(self,mid,fact):return ModelMemoryExtractor(Fake(pack({'facts':[fact]}))).extract(self.s,mid)
    def test_pasted_source_retained_not_user_belief_or_verified(self):
        mid=self.s.add('user','Pasted article: spaced practice improves recall.',self.t);fact=proposal(mid,'spaced practice improves recall');i=self.extract(mid,fact)[0];m=self.s.get_memory(i)['metadata'];self.assertEqual(m['knowledge_type'],'source_claim');self.assertEqual(m['attribution'],'quoted_source');self.assertEqual(m['epistemic_status'],'unverified');self.assertEqual(m['sources'],[mid]);retrieved=self.s.search_memory(self.t)[0];self.assertEqual(retrieved['attribution'],'quoted_source')
        fact.update(knowledge_type='user_belief',attribution='user',epistemic_status='user_stated')
        with self.assertRaises(AdapterError):self.extract(mid,fact)
        fact.update(knowledge_type='source_claim',attribution='quoted_source',epistemic_status='verified')
        with self.assertRaises(AdapterError):self.extract(mid,fact)
    def test_generated_synthesis_and_hypothesis_preserve_uncertainty(self):
        mid=self.s.add('assistant','Combining retrieval practice with spacing offers a coherent study plan.',self.t);i=self.extract(mid,proposal(mid,'Combining retrieval practice with spacing offers a coherent study plan.','topic_synthesis','assistant'))[0];self.assertEqual(self.s.get_memory(i)['metadata']['origin_role'],'assistant');self.assertEqual(self.s.search_memory(self.t)[0]['epistemic_status'],'unverified')
        hypothesis=self.s.add('assistant','Perhaps a shorter review interval helps beginners.',self.t);f=proposal(hypothesis,'Perhaps a shorter review interval helps beginners.','tentative_hypothesis','assistant','tentative',key='review.hypothesis');h=self.extract(hypothesis,f)[0];self.assertEqual(self.s.get_memory(h)['metadata']['epistemic_status'],'tentative')
        f.update(knowledge_type='user_belief',attribution='user',epistemic_status='user_stated')
        with self.assertRaises(AdapterError):self.extract(hypothesis,f)
    def test_attribution_boundaries_coexist_and_corrections_keep_lineage(self):
        user=self.s.add('user','I prefer short study sessions.',self.t);u=self.extract(user,proposal(user,'I prefer short study sessions.','user_preference','user','user_stated',key='study.length'))[0]
        worker=self.s.add('assistant','Long sessions help solve this synthetic puzzle.',self.t);f=proposal(worker,'Long sessions help solve this synthetic puzzle.','generated_analysis','assistant',key='study.length');w=self.extract(worker,f)[0];self.assertNotEqual(u,w);self.assertEqual(len(self.s.search_memory(self.t)),2)
        f['replaces_id']=u
        with self.assertRaises(AdapterError):self.extract(worker,f)
        revision=self.s.add('assistant','Correction: short sessions better fit this synthetic puzzle.',self.t);f=proposal(revision,'short sessions better fit this synthetic puzzle.','generated_analysis','assistant',key='study.length',replaces=w);self.assertEqual(self.extract(revision,f),[w]);meta=self.s.get_memory(w)['metadata'];self.assertEqual(meta['lineage'][0]['attribution'],'assistant');self.assertEqual(meta['sources'],[revision]);before=self.s.rows('SELECT * FROM messages');self.s.forget_memory(w);self.s.rebuild();self.assertEqual(before,self.s.rows('SELECT * FROM messages'));self.assertEqual(self.s.search_memory(self.t)[0]['id'],u)
    def test_secrets_never_sent_to_extractor_or_written(self):
        for role in ('user','assistant'):
            mid=self.s.add(role,'Source credential: sk-syntheticplaceholder123456',self.t);model=Fake('{"facts":[]}');self.assertEqual(ModelMemoryExtractor(model).extract(self.s,mid),[]);self.assertFalse(model.calls)
        mid=self.s.add('assistant','A useful synthetic conclusion.',self.t);f=proposal(mid,'A useful synthetic conclusion.','generated_analysis','assistant',value='password=synthetic-placeholder')
        with self.assertRaises(AdapterError):self.extract(mid,f)
        self.assertFalse(self.s.search_memory(self.t))
    def test_completed_worker_knowledge_is_automatically_scheduled(self):
        class Secretary:
            name='TEST'
            def generate(self,c):return pack({'action':'delegate','topic_id':c['candidates'][0]['id'],'new_topic':'','instruction':'Analyze','reply':'','task_id':None})
        class KnowledgeModel:
            def generate(self,c):
                source=c['source']
                if source['role']=='user':return '{"facts":[]}'
                return pack({'facts':[proposal(source['id'],source['body'],'generated_analysis','assistant')]})
        app=App(self.temp.name,Orchestrator(Secretary(),Fake('Spaced practice is a useful study strategy.')),ModelMemoryExtractor(KnowledgeModel()))
        try:
            app.post('/api/send',{'body':'Analyze this study approach','topic':self.t});end=time.time()+3
            while time.time()<end and not self.s.search_memory(self.t):time.sleep(.01)
            notes=self.s.search_memory(self.t);self.assertEqual(len(notes),1);meta=self.s.get_memory(notes[0]['id'])['metadata'];self.assertEqual(meta['source_kind'],'worker_output');self.assertEqual(meta['attribution'],'assistant');source=self.s.rows('SELECT * FROM messages WHERE id=?',(meta['sources'][0],))[0];self.assertEqual(source['role'],'assistant');self.assertEqual(source['body'],'Spaced practice is a useful study strategy.')
        finally:app.close()
    def test_long_worker_output_is_excerpted_without_rewriting_history(self):
        body='Intro synthesis. '+('Synthetic background. '*900)+'Final useful conclusion.';mid=self.s.add('assistant',body,self.t);f=proposal(mid,'Final useful conclusion.','topic_synthesis','assistant');model=Fake(pack({'facts':[f]}));ModelMemoryExtractor(model).extract(self.s,mid);context=model.calls[0];self.assertTrue(context['source']['excerpted']);self.assertLessEqual(len(pack(context).encode()),12000);self.assertEqual(self.s.rows('SELECT body FROM messages WHERE id=?',(mid,))[0]['body'],body)
    def test_worker_can_retain_cited_source_without_owning_its_claim(self):
        mid=self.s.add('assistant','The cited article claims that spaced practice improves recall.',self.t);i=self.extract(mid,proposal(mid,'spaced practice improves recall'))[0];meta=self.s.get_memory(i)['metadata'];self.assertEqual(meta['origin_role'],'assistant');self.assertEqual(meta['attribution'],'quoted_source');self.assertEqual(meta['epistemic_status'],'unverified')
    def test_contrasting_source_does_not_silently_replace_prior_claim(self):
        m=self.s.add('user','Pasted source A: shorter practice is better.',self.t);i=self.extract(m,proposal(m,'shorter practice is better'))[0];m2=self.s.add('user','Pasted source B: longer practice is better.',self.t);f=proposal(m2,'longer practice is better',replaces=i)
        with self.assertRaises(AdapterError):self.extract(m2,f)
        f['replaces_id']=None;j=self.extract(m2,f)[0];self.assertNotEqual(i,j);self.assertEqual(len(self.s.search_memory(self.t)),2)
