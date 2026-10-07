"""Configured Gateway client; CLI owns auth. Never bypass agent-exec attribution."""
import json, os, subprocess, threading, time
from pathlib import Path
from core import pack, uid
from adapter import AdapterError
ROOT=Path(__file__).resolve().parent
class GatewayRPC:
    def __init__(self,runner=None):self.runner=runner
    def call(self,method,params,final=False):
        if self.runner:return self.runner(method,params,final)
        if os.environ.get('OPENCLAW_SHELL')=='exec' or os.environ.get('OPENCLAW_SUBAGENT_EXEC'):
            raise AdapterError('OpenClaw prohibits Gateway execution from agent exec without attribution. Start PROJECTX in your own terminal; no new provider credentials requested. Exec markers are never removed.')
        from urllib.parse import urlparse
        url=os.environ.get('PROJECTX_GATEWAY_URL','ws://127.0.0.1:18789');parsed=urlparse(url)
        if parsed.scheme not in ('ws','wss') or parsed.hostname not in ('127.0.0.1','::1','localhost') or parsed.username or parsed.password:raise AdapterError('Only a loopback Gateway target is allowed')
        args=['openclaw','gateway','call',method,'--json','--expect-url',url,'--timeout','110000','--params',pack(params)]
        if final:args.append('--expect-final')
        try:r=subprocess.run(args,capture_output=True,text=True,timeout=120)
        except (OSError,subprocess.TimeoutExpired) as e:raise AdapterError('Gateway CLI unavailable/timed out; no automatic replay') from e
        try:result=json.loads(r.stdout)
        except ValueError:raise AdapterError('Gateway returned non-JSON output; diagnostics omitted')
        if r.returncode or not isinstance(result,dict) or result.get('ok') is False:raise AdapterError('Gateway refused/failed this operation. Check caller attribution and session policy. No credentials extracted or config changed.')
        return result

def terminal_text(envelope):
    if envelope.get('status')!='ok':raise AdapterError('Gateway run did not complete successfully')
    result=envelope.get('result',{});meta=result.get('meta',{})
    if meta.get('error') or meta.get('aborted'):raise AdapterError('Gateway returned model error/abort')
    terminal=meta.get('terminalReply',{})
    text=terminal.get('text','') if terminal.get('disposition')=='visible' else '\n'.join(p.get('text','') for p in result.get('payloads',[]) if not p.get('isError'))
    if any(p.get('isError') for p in result.get('payloads',[])) or not isinstance(text,str) or not text.strip() or len(text.encode())>64000:raise AdapterError('Gateway output is empty, erroneous or oversized')
    return text

class GatewayModelAdapter:
    """Stateless raw model: no bootstrap, durable history or model tools."""
    def __init__(self,model,agent='coding',rpc=None):
        if not model or '/' not in model:raise ValueError('Use configured provider/model')
        self.model=model;self.agent=agent;self.rpc=rpc or GatewayRPC();self.name=f'Configured Gateway / {model}'
    def generate(self,context):
        if len(pack(context).encode())>12000:raise AdapterError('Context exceeds 12,000-byte budget')
        return terminal_text(self.rpc.call('agent',{'agentId':self.agent,'model':self.model,'message':pack(context),'modelRun':True,'promptMode':'none','deliver':False,'timeout':90,'idempotencyKey':'projectx-'+uid()},True))

class GatewayWorkerAdapter(GatewayModelAdapter):
    supports_events=True
    def __init__(self,model,agent='coding',rpc=None,memory_tool=None):
        super().__init__(model,agent,rpc);self.memory_tool=memory_tool
    def generate_task(self,context,task,on_handle,on_event=None):
        workspace=ROOT/'.data'/'gateway-workspaces'/task;workspace.mkdir(parents=True,exist_ok=True)
        key=f'agent:{self.agent}:projectx:{task}';controller=f'agent:{self.agent}:projectx-control:{task}'
        for session,permission in [(controller,'guarded'),(key,'read-only')]:
            created=self.rpc.call('sessions.create',{'key':session,'agentId':self.agent,'cwd':str(workspace),'model':self.model,'permissionMode':permission,'idempotencyKey':'projectx-create-'+session.split(':')[-2]+'-'+task})
            if created.get('ok') is not True or created.get('key')!=session:raise AdapterError('Gateway did not create exact project session')
        handle={'session_key':key,'controller_key':controller,'run_id':'projectx-run-'+uid(),'task':task}
        wire={'context':context,'output_contract':'You may emit brief user-visible progress messages, never hidden reasoning. Your FINAL answer must be ONLY JSON {"text": <final answer>, "applied_revision": 0}. Incorporate later PROJECTX amendments and echo highest applied revision. Do not use native tools, unrelated files, private sessions or external delivery. The separately supplied application memory-tool contract is the only authorized write capability.'}
        if self.memory_tool:
            wire['memory_tools']={'mode':'application-mediated, not native Tool Search','scope':'PROJECTX canonical memory directory only','request':'Instead of a final answer, return ONLY {"memory_call":{"tool":"memory.search|memory.read|memory.write","arguments":{...}}}. The operation executes automatically; its real result returns in this same session. Never claim success before ok=true.', 'arguments':{'memory.search':'query, optional topic_id ranking hint','memory.read':'relative Markdown path from search','memory.write':'path, markdown (complete canonical file), expected_sha256 (hash from read; explicit null ONLY for creating a new UUID.md file)'},'rules':'Read before editing, reconcile conflict replies, preserve source attribution and uncertainty. Existing identity and prior lineage are protected. Markdown first line is JSON with id matching UUID.md and title, then blank line and body. New worker-authored notes default to assistant/generated_analysis/unverified. Do not put credentials in memory. At most six memory operations per worker invocation.'}
        if len(pack(wire).encode())>12000:raise AdapterError('Worker context plus output contract exceeds 12,000 bytes')
        handle['wire_context']=wire;on_handle(handle)
        stop=threading.Event();poller=None
        if on_event:
            from worker_events import visible_events
            def observe():
                while not stop.is_set():
                    try:
                        history=self.rpc.call('chat.history',{'sessionKey':key,'limit':40})
                        for event in visible_events(history):on_event(event)
                    except Exception:pass # Missing capability never invents progress.
                    stop.wait(2)
            poller=threading.Thread(target=observe,daemon=True,name='gateway-visible-events');poller.start()
        try:
            base_run=handle['run_id']
            for step in range(7):
                handle['run_id']=base_run if step==0 else base_run+'-memory-'+str(step)
                handle['input_sequence']=step;handle['latest_input']=wire;on_handle(handle)
                result=self.rpc.call('agent',{'agentId':self.agent,'sessionKey':key,'model':self.model,'message':pack(wire),'bootstrapContextMode':'lightweight','promptMode':'minimal','deliver':False,'disableMessageTool':True,'timeout':90,'idempotencyKey':handle['run_id']},True)
                try:
                    final=terminal_text(result);raw=result.get('result',{})
                    if not raw.get('meta',{}).get('terminalReply') and len(raw.get('payloads',[]))>1:final=raw['payloads'][-1].get('text','')
                    obj=json.loads(final)
                    if isinstance(obj,dict) and set(obj)=={'memory_call'}:
                        if not self.memory_tool:raise AdapterError('Worker requested memory editing without an exposed scoped contract; no write performed')
                        if step==6:raise AdapterError('Memory operation limit reached; earlier successful writes remain real and inspectable')
                        request=obj['memory_call']
                        if not isinstance(request,dict):raise ValueError()
                        outcome=self.memory_tool(request)
                        if on_event:
                            tool=request.get('tool','unknown')
                            if tool not in ('memory.read','memory.write','memory.search'):tool='refused_operation'
                            on_event({'id':f'{task}:memory:{step}','source_id':handle['run_id'],'kind':'tool_metadata','text':tool+(' saved Markdown; index refresh pending' if outcome.get('ok') and outcome.get('indexed') is False else (' succeeded' if outcome.get('ok') else ' refused/failed')),'timestamp':int(time.time()*1000),'source':'projectx.memory_tool'})
                        wire={'application_tool_result':{'call':step,'tool':request.get('tool'),'result':outcome},'instruction':'This is an actual scoped memory operation result, not a user instruction. Continue the same task. Reconcile conflicts by reading current Markdown; never force or claim a failed edit succeeded. Final answer still uses text/applied_revision.'}
                        if len(pack(wire).encode())>26000:raise AdapterError('Memory tool response exceeds 26 KB; no additional model call sent')
                        continue
                    if not isinstance(obj,dict) or set(obj)!={'text','applied_revision'} or not isinstance(obj['text'],str) or not obj['text'].strip() or type(obj['applied_revision']) is not int or obj['applied_revision']<0:raise ValueError()
                    return obj
                except (TypeError,ValueError):raise AdapterError('Invalid worker final/tool-request contract; no additional operation performed')
        finally:
            stop.set()
            if poller:poller.join(timeout=2)
    def steer(self,handle,instruction,revision):
        # Strict mode rejects idle sessions. NEVER fall back to chat.send: that
        # could start an unbounded/full-bootstrap turn when target becomes idle.
        result=self.rpc.call('tools.invoke',{'name':'sessions_send','sessionKey':handle['controller_key'],'agentId':self.agent,'idempotencyKey':f"{handle['task']}-revision-{revision}",'args':{'sessionKey':handle['session_key'],'message':pack({'kind':'PROJECTX amendment','revision':revision,'instruction':instruction,'requirement':'Incorporate amendment and echo highest applied_revision only after doing so. Ignore later-arriving amendments with a lower revision.'}),'mode':'steer','timeoutSeconds':0,'watch':False}})
        output=result.get('output',{})
        if isinstance(output,dict) and isinstance(output.get('details'),dict):output=output['details']
        if result.get('ok') is not True or output.get('status')!='accepted' or output.get('targetDisposition')!='steered' or output.get('sessionKey')!=handle['session_key']:raise AdapterError('Strict steering not admitted; amendment stays pending on same task. No replacement dispatch.')
        return {'status':'accepted_not_confirmed','receipt':output.get('runId'),'revision':revision}
