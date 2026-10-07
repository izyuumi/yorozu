import tempfile,unittest
from core import Store,pack,BUDGET
from memory_tool import invoke
class GlobalMemoryTests(unittest.TestCase):
    def test_relevant_memory_crosses_topics_but_conversation_does_not(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);a=s.topic('Garden');b=s.topic('Research');s.add('user','OTHER_TOPIC_CONVERSATION_ONLY',b);note=s.write_memory(b,'Garden watering research','Garden seedlings benefit from measured watering.');s.write_memory(a,'Unrelated receipt','An unrelated purchase receipt.');mid=s.add('user','Explain garden watering for seedlings.',a);c=s.context(mid);self.assertIn(note,[m['id'] for m in c['memory']]);self.assertEqual(c['memory'][0]['topic'],b);self.assertNotIn('OTHER_TOPIC_CONVERSATION_ONLY',pack(c));self.assertNotIn('purchase receipt',pack(c));self.assertLessEqual(len(pack(c).encode()),BUDGET);s.db.close()
    def test_tool_global_search_and_topic_hint_not_filter(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);a=s.topic('A');b=s.topic('B');i=s.write_memory(b,'Spacing research','Spacing improves retention.');without=invoke(s,{'tool':'memory.search','arguments':{'query':'spacing'}});with_hint=invoke(s,{'tool':'memory.search','arguments':{'query':'spacing','topic_id':a}});self.assertEqual(without['results'][0]['id'],i);self.assertEqual(with_hint['results'][0]['id'],i);s.db.close()
    def test_memory_without_topic_and_removed_topic_rebuild(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);i=s.write_memory(None,'General note','Portable knowledge.');t=s.topic('Temporary provenance');j=s.write_memory(t,'Another note','More portable knowledge.');s.db.execute('DELETE FROM topics WHERE id=?',(t,));s.db.commit();self.assertEqual(s.rebuild(),2);self.assertEqual({m['id'] for m in s.search_memory(query='portable')},{i,j});s.db.close()
    def test_index_discovers_path_then_reads_current_markdown(self):
        with tempfile.TemporaryDirectory() as root:
            s=Store(root);i=s.write_memory(None,'Spacing','Old spacing conclusion.');path=s.memory/s.get_memory(i)['path'];header=path.read_text().split('\n\n')[0];path.write_text(header+'\n\nRevised spacing conclusion.\n');self.assertEqual(s.search_memory(query='spacing')[0]['body'].strip(),'Revised spacing conclusion.');self.assertEqual(s.rows('SELECT summary FROM memory_index')[0]['summary'].strip(),'Old spacing conclusion.');s.rebuild();self.assertIn('Revised',s.rows('SELECT summary FROM memory_index')[0]['summary']);s.db.close()
