"""Focused native UI source-contract checks, NOT rendered/visual acceptance.
Run explicitly: python3 tests/ui_contract_topic_visibility.py
Kept separate from the historical Python runtime regression suite.
"""
import hashlib,re,sys,unittest
from pathlib import Path
PATH=Path(__file__).resolve().parents[1]/'Sources/ProjectXApp/ProjectX.swift'
SOURCE_BYTES=PATH.read_bytes()
SOURCE=SOURCE_BYTES.decode('utf-8')
def section(start,end):
    return SOURCE.split(start,1)[1].split(end,1)[0]
class TopicVisibilityContract(unittest.TestCase):
    def test_main_message_cards_do_not_add_topic_labels_or_ids(self):
        card=section('struct MessageCard: View {','struct MainChat: View {')
        self.assertIn('Text(message.body)',card)
        self.assertNotRegex(card,r'\btopic(?:ID|Id|\.label)?\b')
        self.assertNotIn('Text(message.id',card)
        main=section('struct MainChat: View {','struct InspectionPane: View {')
        self.assertIn('MessageCard(message: $0)',main)
    def test_subchat_header_and_navigation_show_human_topic_labels(self):
        inspection=section('struct InspectionPane: View {','struct ContentView: View {')
        self.assertRegex(inspection,r'Text\(topic\.label\)\s*\.font\(\.(?:headline|title|title2|title3|largeTitle)\)')
        navigation=section('struct ContentView: View {','final class Delegate:')
        self.assertIn('List(model.snapshot.topics)',navigation)
        self.assertIn('Text(topic.label)',navigation)
        self.assertIn('InspectionPane(model: model,topic: topic)',navigation)
    def test_subchat_is_inspect_only_and_main_retains_the_composer(self):
        inspection=section('struct InspectionPane: View {','struct ContentView: View {')
        self.assertIn('Inspect only',inspection)
        self.assertNotRegex(inspection,r'\b(?:TextEditor|TextField|SecureField)\s*\(')
        self.assertNotIn('model.send()',inspection)
        main=section('struct MainChat: View {','struct InspectionPane: View {')
        self.assertIn('TextEditor(text: $model.draft)',main)
        self.assertIn('model.send()',main)
if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(TopicVisibilityContract))
    print('Checked Swift source SHA-256:',hashlib.sha256(SOURCE_BYTES).hexdigest())
    sys.exit(0 if result.wasSuccessful() else 1)
