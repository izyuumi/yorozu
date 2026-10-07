"""Historical Python-prototype integration probe, not native Swift acceptance.
Owner-terminal only; never strips exec attribution.
Run: python3 probe_gateway.py [--steer | --memory]
Creates only fresh project worker/controller sessions; never reads other sessions.
"""
import argparse,json,threading,time
from pathlib import Path
from memory_tool import MemoryTools
from core import uid
from adapter import AdapterError
from gateway_adapter import GatewayRPC,GatewayModelAdapter,GatewayWorkerAdapter

def main():
    p=argparse.ArgumentParser();group=p.add_mutually_exclusive_group();group.add_argument('--steer',action='store_true');group.add_argument('--memory',action='store_true');a=p.parse_args()
    rpc=GatewayRPC();secretary=GatewayModelAdapter('openai-pool/gpt-6-astra',rpc=rpc)
    memory_id=uid();memory_path=memory_id+'.md';marker='PROJECTX_SYNTHETIC_MEMORY_'+uid()
    memory_root=Path(__file__).resolve().parent/'.data'/'probes'/uid()
    memory_service=MemoryTools(memory_root) if a.memory else None
    worker=GatewayWorkerAdapter('openai-pool/gpt-6-sol',rpc=rpc,memory_tool=memory_service)
    report={'transport':'configured Gateway CLI','synthetic':True,'secretary_model':secretary.model,'worker_model':worker.model}
    try:
        route=secretary.generate({'instruction':'Return only JSON {"action":"delegate","instruction":"Compute 17 + 25. Return 42."}','message':'What is 17 + 25?'})
        decision=json.loads(route)
        if decision.get('action')!='delegate' or not isinstance(decision.get('instruction'),str):raise AdapterError('Synthetic secretary returned invalid delegation')
        report['secretary']='passed';handle={};ready=threading.Event();result={};events=[]
        instruction=decision['instruction'] if not a.steer else 'Write a detailed 1500-word comparison of three approaches to organizing synthetic study notes. You may receive a shortening amendment. Do not use tools.'
        if a.memory:
            markdown=json.dumps({'id':memory_id,'title':'Synthetic worker-edit probe'})+'\n\n'+marker+'\n'
            instruction='Use the supplied memory.write tool contract to create '+memory_path+' with expected_sha256=null and this exact canonical Markdown: '+markdown+' Then use memory.read to read that same file back. Do not access any other memory or tools. Return a short final answer only after checking both actual receipts.'
        context={'current':{'id':'synthetic','role':'user','body':instruction},'history':[],'memory':[],'delegation':instruction}
        def received(h):handle.update(h);ready.set()
        def run():
            try:result['output']=worker.generate_task(context,uid(),received,events.append if a.memory else None)
            except Exception as e:result['error']=str(e)
        thread=threading.Thread(target=run);thread.start()
        if not ready.wait(30):raise AdapterError('Fresh worker session was not ready within 30 seconds')
        if a.steer:
            deadline=time.time()+15;active=False
            while thread.is_alive() and time.time()<deadline:
                snapshot=rpc.call('chat.history',{'sessionKey':handle['session_key'],'limit':1})
                if snapshot.get('sessionInfo',{}).get('hasActiveRun'):active=True;break
                time.sleep(.5)
            if active:
                report['steering_receipt']=worker.steer(handle,'Replace the long comparison with exactly one sentence recommending an approach for synthetic study notes.',1)
            else:report['steering']='not attempted: no active worker observed; no idle-target fallback'
        thread.join(110)
        if thread.is_alive():raise AdapterError('Worker remains unfinished; do not replay')
        if result.get('error'):raise AdapterError(result['error'])
        report['worker_output']=result['output'];report['worker']='passed'
        if a.memory:
            actual=memory_service({'tool':'memory.read','arguments':{'path':memory_path}})
            discovery=memory_service({'tool':'memory.search','arguments':{'query':marker}})
            operations=[e['text'] for e in events if e['source']=='projectx.memory_tool']
            verified=actual.get('ok') and marker in actual.get('markdown','') and 'memory.write succeeded' in operations and 'memory.read succeeded' in operations and any(r['id']==memory_id for r in discovery.get('results',[]))
            report.update(memory_scope='isolated project-owned synthetic fixture',memory_verified=bool(verified),memory_operations=operations,memory_fixture=str(memory_root.relative_to(Path(__file__).resolve().parent)))
            if not verified:raise AdapterError('Worker-directed write/read/index verification did not pass; no live memory success claimed')
        if a.steer:report['steering_applied_reported']=result['output']['applied_revision']==1 and bool(report.get('steering_receipt'))
        print(json.dumps(report,ensure_ascii=False,indent=2))
    except (AdapterError,ValueError) as e:
        report.update(status='blocked_or_failed',error=str(e));print(json.dumps(report,indent=2));raise SystemExit(1)
if __name__=='__main__':main()
