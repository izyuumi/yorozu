import hashlib,json,multiprocessing,os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from core import Store,pack,uid
from memory_tool import MemoryTools,invoke
from memory_fs import MemoryConflict
from memory_files import read_file,write_file

def document(identifier,body,**meta):return pack({'id':identifier,'title':'Worker note',**meta})+'\n\n'+body+'\n'
def competing_write(root,path,text,version,ready,start,results):
    ready.put(True);start.wait(10);results.put(MemoryTools(root)({'tool':'memory.write','arguments':{'path':path,'markdown':text,'expected_sha256':version}}))

class MemoryWriteTests(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.s=Store(Path(self.temp.name)/'app');self.service=MemoryTools(self.s.root)
    def tearDown(self):self.s.db.close();self.temp.cleanup()
    def create(self,body='Original worker text'):
        identifier=uid();path=identifier+'.md';reply=self.service({'tool':'memory.write','arguments':{'path':path,'markdown':document(identifier,body),'expected_sha256':None}});self.assertTrue(reply['ok'],reply);return identifier,path,reply
    def test_actual_create_read_edit_refresh_and_history_preservation(self):
        topic=self.s.topic('Conversation');m=self.s.add('user','Original chat must remain byte-for-byte.',topic);before=self.s.rows('SELECT * FROM messages');i,path,created=self.create();snapshot=invoke(self.s,{'tool':'memory.read','arguments':{'path':path}});self.assertEqual(snapshot['sha256'],hashlib.sha256((self.s.memory/path).read_bytes()).hexdigest())
        changed=snapshot['markdown'].replace('Original worker text','Worker-chosen revised Markdown **body**');reply=invoke(self.s,{'tool':'memory.write','arguments':{'path':path,'markdown':changed,'expected_sha256':snapshot['sha256']}});self.assertTrue(reply['changed']);self.assertTrue(reply['indexed']);note=self.s.get_memory(i);self.assertEqual(note['body'],'Worker-chosen revised Markdown **body**\n');self.assertEqual(note['metadata']['last_editor'],'worker');self.assertEqual(note['metadata']['epistemic_status'],'unverified');self.assertEqual(note['metadata']['lineage'][-1]['body'],'Original worker text\n');self.assertEqual(self.s.search_memory(query='revised')[0]['id'],i);self.assertEqual(before,self.s.rows('SELECT * FROM messages'))
    def test_stale_write_and_create_collision_do_not_lose_changes(self):
        i,path,created=self.create();old=read_file(self.s,path);first=write_file(self.s,path,old['markdown'].replace('Original','First'),old['sha256']);
        with self.assertRaises(MemoryConflict):write_file(self.s,path,old['markdown'].replace('Original','Stale second'),old['sha256'])
        with self.assertRaises(MemoryConflict):write_file(self.s,path,document(i,'Replacement'),None)
        self.assertEqual(read_file(self.s,path)['sha256'],first['sha256']);self.assertIn('First worker text',self.s.search_memory(query='First')[0]['body'])
    def test_path_symlink_and_hardlink_refusals(self):
        i=uid();outside=Path(self.temp.name)/(i+'.md');outside.write_text(document(i,'Outside remains untouched'));original=outside.read_bytes();outside_dir=outside.parent
        for path in ['../'+outside.name,str(outside),'x/../../'+outside.name,'x\\'+outside.name]:
            result=self.service({'tool':'memory.write','arguments':{'path':path,'markdown':document(i,'BAD'),'expected_sha256':None}});self.assertFalse(result['ok'])
        (self.s.memory/'escape').symlink_to(outside_dir,target_is_directory=True)
        for name in ['escape/'+outside.name,outside.name]:
            if name==outside.name:(self.s.memory/name).symlink_to(outside)
            for tool,args in [('memory.read',{'path':name}),('memory.write',{'path':name,'markdown':document(i,'BAD'),'expected_sha256':hashlib.sha256(original).hexdigest()})]:self.assertFalse(self.service({'tool':tool,'arguments':args})['ok'])
        (self.s.memory/outside.name).unlink();os.link(outside,self.s.memory/outside.name);self.assertFalse(self.service({'tool':'memory.read','arguments':{'path':outside.name}})['ok']);self.assertEqual(outside.read_bytes(),original)
    def test_atomic_replacement_failure_keeps_original_and_cleans_temp(self):
        _,path,_=self.create();old=read_file(self.s,path)
        with patch('memory_files.os.replace',side_effect=OSError('synthetic rename failure')):
            with self.assertRaises(OSError):write_file(self.s,path,old['markdown'].replace('Original','New'),old['sha256'])
        self.assertEqual(read_file(self.s,path),old);self.assertFalse(list(self.s.memory.glob('*.tmp')))
    def test_worker_cannot_forge_verified_or_unsupported_user_belief(self):
        i=uid()
        for metadata in [{'epistemic_status':'verified'},{'knowledge_type':'user_belief','attribution':'user','epistemic_status':'user_stated','sources':[],'evidence':'invented quote'},{'sources':[uid()]}]:
            reply=self.service({'tool':'memory.write','arguments':{'path':i+'.md','markdown':document(i,'Claim',**metadata),'expected_sha256':None}});self.assertFalse(reply['ok'])
        self.assertFalse(self.s.search_memory())
    def test_workers_can_write_supported_user_preference_with_real_provenance(self):
        t=self.s.topic('Preferences');m=self.s.add('user','I prefer concise answers.',t);i=uid();data=document(i,'Prefers concise answers.',knowledge_type='user_preference',attribution='user',epistemic_status='user_stated',sources=[m],evidence='I prefer concise answers.')
        result=write_file(self.s,i+'.md',data,None);self.assertTrue(result['indexed']);meta=self.s.get_memory(i)['metadata'];self.assertEqual(meta['origin_role'],'user');self.assertEqual(meta['last_editor'],'worker')
    def test_cross_process_competing_writes_have_one_winner(self):
        i,path,_=self.create();snapshot=read_file(self.s,path);ctx=multiprocessing.get_context('spawn');ready=ctx.Queue();results=ctx.Queue();start=ctx.Event();processes=[]
        for label in ('One','Two'):
            p=ctx.Process(target=competing_write,args=(str(self.s.root),path,snapshot['markdown'].replace('Original',label),snapshot['sha256'],ready,start,results));p.start();processes.append(p)
        try:
            ready.get(timeout=10);ready.get(timeout=10);start.set();out=[results.get(timeout=10),results.get(timeout=10)];self.assertEqual(sum(r['ok'] for r in out),1);self.assertEqual([r['error_code'] for r in out if not r['ok']],['conflict']);self.assertIn(self.s.get_memory(i)['body'],['One worker text\n','Two worker text\n'])
        finally:
            start.set()
            for p in processes:p.join(10)
            for p in processes:
                if p.is_alive():p.terminate();p.join()
    def test_worker_store_cannot_mutate_operational_chat_even_internally(self):
        import sqlite3
        topic=self.s.topic('Original');message=self.s.add('user','Never modify this original.',topic);worker=Store(self.s.root,memory_tools_only=True)
        try:
            with self.assertRaises(sqlite3.OperationalError):worker.db.execute("UPDATE messages SET body='BAD' WHERE id=?",(message,))
            worker.db.rollback();self.assertEqual(worker.rows('SELECT body FROM messages WHERE id=?',(message,))[0]['body'],'Never modify this original.')
        finally:worker.db.close()
    def test_scoped_unicode_subdirectory_is_editable(self):
        (self.s.memory/'研究').mkdir();identifier=uid();path='研究/'+identifier+'.md';reply=self.service({'tool':'memory.write','arguments':{'path':path,'markdown':document(identifier,'Portable topic knowledge.'),'expected_sha256':None}});self.assertTrue(reply['ok'],reply);self.assertEqual(self.s.get_memory(identifier)['path'],path)
    def test_memory_root_symlink_is_refused(self):
        outside=Path(self.temp.name)/'outside';outside.mkdir();marker=outside/'keep.txt';marker.write_text('untouched');self.s.memory.rmdir();self.s.memory.symlink_to(outside,target_is_directory=True);identifier=uid();reply=self.service({'tool':'memory.write','arguments':{'path':identifier+'.md','markdown':document(identifier,'BAD'),'expected_sha256':None}});self.assertFalse(reply['ok']);self.assertEqual(marker.read_text(),'untouched');self.assertFalse((outside/(identifier+'.md')).exists())
    def test_index_failure_does_not_hide_successful_canonical_write(self):
        identifier,path,_=self.create();snapshot=read_file(self.s,path);real=self.s.rebuild;calls=[]
        def rebuild():
            calls.append(1)
            if len(calls)==2:raise RuntimeError('synthetic index outage')
            return real()
        with patch.object(self.s,'rebuild',side_effect=rebuild):reply=write_file(self.s,path,snapshot['markdown'].replace('Original','Updated'),snapshot['sha256'])
        self.assertTrue(reply['changed']);self.assertFalse(reply['indexed']);self.assertIn('Updated worker text',read_file(self.s,path)['markdown']);self.s.rebuild();self.assertEqual(self.s.search_memory(query='Updated')[0]['id'],identifier)
    def test_external_credential_note_is_withheld_from_worker_reads_and_context(self):
        identifier=self.s.write_memory(None,'Synthetic note','Originally harmless.');note=self.s.get_memory(identifier);path=self.s.memory/note['path'];header=path.read_text().split('\n\n',1)[0];path.write_text(header+'\n\npassword: synthetic-placeholder\n');self.s.rebuild();reply=self.service({'tool':'memory.search','arguments':{'query':'Synthetic note'}});self.assertEqual(reply['results'],[]);self.assertEqual(reply['withheld'],1);self.assertFalse(self.service({'tool':'memory.read','arguments':{'path':note['path']}})['ok']);topic=self.s.topic('Discussion');m=self.s.add('user','Discuss the synthetic note.',topic);self.assertNotIn('synthetic-placeholder',pack(self.s.context(m)));self.assertIn('synthetic-placeholder',path.read_text())
    def test_benign_token_budget_knowledge_is_not_a_credential(self):
        identifier,path,_=self.create('Token budgets constrain model context windows.');reply=self.service({'tool':'memory.read','arguments':{'path':path}});self.assertTrue(reply['ok']);self.assertEqual(self.s.search_memory(query='token budgets')[0]['id'],identifier)
    def test_direct_edit_preserves_tentative_attribution_instead_of_promoting_it(self):
        topic=self.s.topic('Research');m=self.s.add('user','Perhaps short reviews improve recall.',topic);identifier=uid();meta={'knowledge_type':'user_belief','attribution':'user','epistemic_status':'user_stated','sources':[m],'evidence':'Perhaps short reviews improve recall.'};bad=self.service({'tool':'memory.write','arguments':{'path':identifier+'.md','markdown':document(identifier,'Short reviews improve recall.',**meta),'expected_sha256':None}});self.assertFalse(bad['ok']);meta.update(knowledge_type='tentative_hypothesis',epistemic_status='tentative');good=self.service({'tool':'memory.write','arguments':{'path':identifier+'.md','markdown':document(identifier,'Perhaps short reviews improve recall.',**meta),'expected_sha256':None}});self.assertTrue(good['ok'],good);self.assertEqual(self.s.get_memory(identifier)['metadata']['epistemic_status'],'tentative')
