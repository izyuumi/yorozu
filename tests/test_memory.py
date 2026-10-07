import unittest,tempfile,json
from core import Store
class MemoryTests(unittest.TestCase):
    def test_auto_provenance_correction_restart_and_edited_markdown(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);topic=s.topic('Profile');m=s.add('user','My timezone is JST.',topic);i=s.extract_memory(m);p=next(s.memory.rglob(i+'.md'));meta=json.loads(p.read_text().split('\n\n')[0]);self.assertEqual(meta['sources'],[m]);self.assertIn('created_at',meta)
            m2=s.add('user','My timezone is UTC.',topic);self.assertEqual(s.extract_memory(m2),i);self.assertEqual(len(list(s.memory.rglob('*.md'))),1);meta=json.loads(p.read_text().split('\n\n')[0]);self.assertEqual(meta['sources'],[m2]);self.assertEqual(meta['lineage'][0]['sources'],[m]);s.db.close();s=Store(root);self.assertEqual(s.search_memory(topic)[0]['body'].strip(),'UTC');header=p.read_text().split('\n\n')[0];p.write_text(header+'\n\nEdited by owner\n');self.assertEqual(s.search_memory(topic)[0]['body'].strip(),'Edited by owner');s.rebuild();self.assertEqual(s.search_memory(topic)[0]['body'].strip(),'Edited by owner');self.assertTrue((s.root/'memory-index.sqlite').exists());self.assertFalse(s.rows("SELECT name FROM main.sqlite_master WHERE name='memory_index'"));s.db.close()
    def test_tentative_secrets_and_worker_claims_not_promoted(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);t=s.topic('Test')
            for body in ['Maybe my timezone is UTC.','My password is synthetic-placeholder.','My timezone is maybe UTC.','I guess I prefer green.']:
                self.assertIsNone(s.extract_memory(s.add('user',body,t)))
            self.assertIsNone(s.extract_memory(s.add('assistant','My timezone is UTC.',t)));self.assertFalse(s.search_memory(t));s.db.close()
