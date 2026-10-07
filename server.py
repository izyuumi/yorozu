import json, os
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from core import Store, pack
from adapter import configured, AdapterError, OpenClawAdapter, DisabledAdapter
from orchestrator import Orchestrator
from core import uid
ROOT=Path(__file__).resolve().parent

class App:
    def __init__(self,root,adapter,extractor=None):
        from concurrent.futures import ThreadPoolExecutor
        self.root=root; self.store=Store(root); self.adapter=adapter; self.extractor=extractor
        self.secretaries=ThreadPoolExecutor(max_workers=2,thread_name_prefix='secretary')
        self.workers=ThreadPoolExecutor(max_workers=2,thread_name_prefix='worker')
        self.memories=ThreadPoolExecutor(max_workers=1,thread_name_prefix='memory')
        self.store.db.execute("UPDATE turns SET status='error',error='Interrupted by restart; no automatic replay' WHERE status='pending'")
        self.store.db.execute("UPDATE tasks SET status='error' WHERE status IN ('routing','queued','working')")
        self.store.db.commit()
    def close(self):
        self.secretaries.shutdown(wait=True); self.workers.shutdown(wait=True); self.memories.shutdown(wait=True); self.store.db.close()
    def extract(self,mid):
        s=Store(self.root)
        try:
            if s.rows('SELECT message FROM memory_jobs WHERE message=?',(mid,)):return
            result=self.extractor.extract(s,mid) if self.extractor else s.extract_memory(mid)
            s.db.execute('INSERT OR REPLACE INTO memory_jobs VALUES (?,?,NULL)',(mid,'saved' if result else 'no_supported_fact'));s.db.commit()
        except Exception:
            s.db.rollback();s.db.execute('INSERT OR REPLACE INTO memory_jobs VALUES (?,?,?)',(mid,'error','Memory extraction/index failed; source message retained'));s.db.commit()
        finally:s.db.close()
    def align_memory(self,mid,topic):
        s=Store(self.root)
        try:s.align_memory_topic(mid,topic)
        except Exception:
            s.db.rollback();s.db.execute('UPDATE memory_jobs SET error=? WHERE message=?',('Memory routing alignment failed; Markdown retained',mid));s.db.commit()
        finally:s.db.close()
    def fail(self,s,mid,task,error):
        s.db.execute("UPDATE turns SET status='error',error=? WHERE message=?",(error,mid))
        s.db.execute("UPDATE tasks SET status='error' WHERE id=?",(task,))
        s.db.execute("UPDATE turns SET status='error',error=? WHERE message IN (SELECT message FROM amendments WHERE task=?)",(error,task));s.db.commit()
    def complete(self,s,mid,task,result):
        text=result['text'] if isinstance(result,dict) else result
        revision=result.get('applied_revision',0) if isinstance(result,dict) else 0
        s.db.execute('BEGIN IMMEDIATE')
        topic=s.rows('SELECT topic FROM messages WHERE id=?',(mid,))[0]['topic']
        s.db.execute('INSERT OR REPLACE INTO output_revisions VALUES (?,?)',(task,revision))
        amendments=s.rows('SELECT * FROM amendments WHERE task=? ORDER BY rowid',(task,))
        applied=bool(amendments) and revision==len(amendments) and all(a['status'] in ('accepted_not_confirmed','applied_confirmed_by_output') for a in amendments)
        stale=bool(amendments) and not applied
        s.db.execute('INSERT OR REPLACE INTO task_results VALUES (?,?,?)',(task,text,'stale' if stale else 'current'))
        if stale:
            s.db.execute("UPDATE tasks SET status='amendment_pending' WHERE id=?",(task,))
            s.db.execute("UPDATE turns SET status='error',error='Result retained in Details but does not confirm the latest amendment. No replacement task or success claimed.' WHERE message=?",(mid,));s.db.commit();return
        if applied:
            s.db.execute("UPDATE amendments SET status='applied_confirmed_by_output' WHERE task=?",(task,))
            s.db.execute("UPDATE turns SET status='done',error=NULL WHERE message IN (SELECT message FROM amendments WHERE task=?)",(task,))
        emitted=None
        if not s.rows("SELECT id FROM messages WHERE reply_to=? AND role='assistant'",(mid,)):
            emitted=s.add('assistant',text,topic,reply_to=mid,commit=False)
        s.db.execute("UPDATE turns SET status='done',error=NULL WHERE message=?",(mid,))
        s.db.execute("UPDATE tasks SET status='done' WHERE id=?",(task,));s.db.commit()
        if emitted and self.extractor:self.memories.submit(self.extract,emitted)
    def execute_worker(self,mid,task,ctx):
        s=Store(self.root)
        try:
            s.db.execute("UPDATE tasks SET status='working' WHERE id=?",(task,));s.db.commit()
            if hasattr(self.adapter.worker,'generate_task'):
                def handle(value):
                    s.db.execute('INSERT OR REPLACE INTO harness_tasks VALUES (?,?)',(task,pack(value)))
                    if 'latest_input' in value:s.db.execute('INSERT OR IGNORE INTO harness_inputs VALUES (?,?,?)',(task,value['input_sequence'],pack(value['latest_input'])))
                    s.db.commit()
                def event(value):
                    events=Store(self.root)
                    try:
                        events.db.execute('INSERT OR IGNORE INTO worker_events(task,event_id,source_id,kind,body,timestamp,source) VALUES (?,?,?,?,?,?,?)',(task,value['id'],value['source_id'],value['kind'],value['text'],str(value.get('timestamp')),value['source']));events.db.commit()
                    finally:events.db.close()
                if getattr(self.adapter.worker,'supports_events',False):result=self.adapter.worker.generate_task(ctx,task,handle,event)
                else:result=self.adapter.worker.generate_task(ctx,task,handle)
            else:result=self.adapter.worker.generate(ctx)
            self.complete(s,mid,task,result)
        except AdapterError as e:self.fail(s,mid,task,str(e))
        except Exception:self.fail(s,mid,task,'Worker failed internally; no automatic replay')
        finally:s.db.close()
    def submit_steer(self,s,target,amendment,mid,instruction):
        rows=s.rows('SELECT handle FROM harness_tasks WHERE task=?',(target,))
        if not rows or not hasattr(self.adapter.worker,'steer'):return
        revision=s.rows('SELECT revision FROM steering_receipts WHERE amendment=?',(amendment,))[0]['revision']
        try:
            handle=json.loads(rows[0]['handle'])
            receipt=self.adapter.worker.steer(handle,instruction,revision)
            s.db.execute('BEGIN IMMEDIATE')
            s.db.execute("UPDATE amendments SET status='accepted_not_confirmed' WHERE id=?",(amendment,))
            s.db.execute('UPDATE steering_receipts SET receipt=? WHERE amendment=?',(pack(receipt),amendment))
            s.db.execute("UPDATE turns SET status='pending',error='Steering accepted; incorporation not yet confirmed.' WHERE message=?",(mid,));s.db.commit()
            prior=s.rows('SELECT r.body,v.revision,t.message FROM task_results r JOIN output_revisions v ON v.task=r.task JOIN tasks t ON t.id=r.task WHERE r.task=?',(target,))
            if prior:self.complete(s,prior[0]['message'],target,{'text':prior[0]['body'],'applied_revision':prior[0]['revision']})
        except AdapterError as e:
            s.db.execute('UPDATE turns SET error=? WHERE message=?',(str(e),mid));s.db.commit()
    def execute_secretary(self,mid,task,body,explicit):
        s=Store(self.root)
        try:
            sc,decision,routed=self.adapter.route(s,body,explicit,mid,task)
            s.correct(mid,routed)
            self.memories.submit(self.align_memory,mid,routed)
            s.db.execute("UPDATE messages SET reason='Secretary routed' WHERE id=?",(mid,))
            s.db.execute('UPDATE secretary_turns SET decision=? WHERE message=?',(pack(decision),mid));s.db.commit()
            if decision['action']=='reply':
                reply_id=s.add('assistant',decision['reply'],routed,reply_to=mid)
                s.db.execute("UPDATE turns SET status='done' WHERE message=?",(mid,));s.db.commit()
                if self.extractor:self.memories.submit(self.extract,reply_id)
                return
            if decision['action']=='steer':
                target=decision['task_id'];amendment=uid()
                s.db.execute('BEGIN IMMEDIATE')
                s.db.execute('INSERT INTO amendments VALUES (?,?,?,?,?)',(amendment,target,mid,decision['instruction'],'pending_unsupported'))
                revision=s.rows('SELECT count(*) AS n FROM amendments WHERE task=?',(target,))[0]['n']
                s.db.execute('INSERT INTO steering_receipts VALUES (?,?,NULL)',(amendment,revision))
                s.db.execute('INSERT INTO turn_tasks VALUES (?,?,?)',(mid,target,'steer'))
                s.db.execute("UPDATE tasks SET status='amendment_pending' WHERE id=?",(target,))
                s.db.execute("UPDATE task_results SET status='stale' WHERE task=?",(target,))
                s.db.execute("UPDATE turns SET status='error',error='Task has an unapplied amendment; any previous result is superseded.' WHERE message=(SELECT message FROM tasks WHERE id=?)",(target,))
                s.db.execute("UPDATE turns SET status='error',error='Amendment saved on the same task, NOT applied yet. Strict steering requires an active supported Gateway worker. No duplicate worker was launched.' WHERE message=?",(mid,));s.db.commit()
                self.submit_steer(s,target,amendment,mid,decision['instruction']);return
            task=uid()
            s.db.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?)',(task,mid,pack(sc),pack(decision),getattr(self.adapter.worker,'model','offline'),'queued'))
            s.db.execute('INSERT INTO turn_tasks VALUES (?,?,?)',(mid,task,'delegate'));s.db.commit()
            ctx=s.context(mid,decision['instruction'],budget=10000 if getattr(self.adapter.worker,'memory_tool',None) else 11500)
            s.db.execute('UPDATE turns SET context=? WHERE message=?',(pack(ctx),mid))
            s.db.execute("UPDATE tasks SET status='queued' WHERE id=?",(task,));s.db.commit()
            self.workers.submit(self.execute_worker,mid,task,ctx)
        except AdapterError as e:self.fail(s,mid,task,str(e))
        except Exception:self.fail(s,mid,task,'Secretary failed internally; worker was not called')
        finally:s.db.close()
    def post(self,path,d):
        s=self.store
        if path=='/api/topics': return {'id':s.topic(d.get('label'))}
        if path=='/api/correct': s.correct(d['message'],d['topic']); return {'ok':True}
        if path=='/api/memory/write': return {'id':s.write_memory(d.get('topic'),d['title'],d['body'])}
        if path=='/api/memory/get':return s.get_memory(d['id'])
        if path=='/api/memory/forget':return {'id':s.forget_memory(d['id'])}
        if path=='/api/memory/rebuild': return {'count':s.rebuild()}
        if path=='/api/memory/search': return {'results':s.search_memory(d.get('topic'),d.get('query',''))}
        if path=='/api/send':
            body=d.get('body')
            if not isinstance(body,str) or not body.strip() or len(body.encode())>6000: raise ValueError('Message must be 1–6000 UTF-8 bytes')
            if s.rows("SELECT count(*) AS n FROM turns WHERE status='pending'")[0]['n']>=32:raise ValueError('32 turns pending; wait for a task to finish')
            topic,reason=s.route(body,d.get('topic'));mid=s.add('user',body,topic,reason=reason);task=uid()
            s.db.execute('INSERT INTO turns VALUES (?,?,?,NULL)',(mid,'{}','pending'))
            s.db.commit()
            self.memories.submit(self.extract,mid)
            self.secretaries.submit(self.execute_secretary,mid,task,body,d.get('topic'))
            return {'message':mid,'status':'routing'}
        raise ValueError('Unknown operation')

class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup(); self.connection.settimeout(5)
    def log_message(self,*args): pass  # never log message contents
    def respond(self,status,obj,ctype='application/json'):
        data=(pack(obj) if ctype=='application/json' else obj).encode()
        self.send_response(status); self.send_header('Content-Type',ctype+'; charset=utf-8'); self.send_header('Content-Length',str(len(data)))
        self.send_header('Cache-Control','no-store'); self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers(); self.wfile.write(data)
    def allowed(self,write=False):
        origin='http://'+self.server.expected_host
        return self.headers.get('Host')==self.server.expected_host and self.headers.get('Sec-Fetch-Site') not in ('cross-site','same-site') and (not write or (self.headers.get('Origin')==origin and self.headers.get('Content-Type','').split(';')[0]=='application/json' and self.headers.get('X-ProjectX')=='1'))
    def do_GET(self):
        if not self.allowed(): return self.respond(403,{'error':'Untrusted host or origin'})
        if self.path=='/api/state': return self.respond(200,{**self.server.app.store.state(),'adapter':self.server.app.adapter.name})
        if self.path.startswith('/api/subchat/'):
            return self.respond(200,self.server.app.store.inspect_subchat(self.path.removeprefix('/api/subchat/')))
        if self.path.startswith('/api/context/'):
            rows=self.server.app.store.rows('SELECT * FROM turns WHERE message=?',(self.path.removeprefix('/api/context/'),))
            return self.respond(200,{'worker':rows[0] if rows else {},'secretary':self.server.app.store.rows('SELECT * FROM secretary_turns WHERE message=?',(self.path.removeprefix('/api/context/'),)), 'events':self.server.app.store.rows('SELECT * FROM worker_events WHERE task IN (SELECT task FROM turn_tasks WHERE message=?) ORDER BY CAST(timestamp AS REAL),ordinal',(self.path.removeprefix('/api/context/'),)), 'memory_jobs':self.server.app.store.rows('SELECT * FROM memory_jobs WHERE message=?',(self.path.removeprefix('/api/context/'),)), 'escalation':self.server.app.store.rows('SELECT * FROM routing_escalations WHERE message=?',(self.path.removeprefix('/api/context/'),)), 'extraction':self.server.app.store.rows('SELECT * FROM extraction_runs WHERE message=?',(self.path.removeprefix('/api/context/'),)), 'harness_inputs':self.server.app.store.rows('SELECT * FROM harness_inputs WHERE task IN (SELECT task FROM turn_tasks WHERE message=?) ORDER BY input_sequence',(self.path.removeprefix('/api/context/'),)), 'harness':self.server.app.store.rows('SELECT * FROM harness_tasks WHERE task IN (SELECT task FROM turn_tasks WHERE message=?)',(self.path.removeprefix('/api/context/'),)), 'tasks':self.server.app.store.rows('SELECT t.*,r.body AS result,r.status AS result_status FROM tasks t LEFT JOIN task_results r ON r.task=t.id WHERE t.id IN (SELECT task FROM turn_tasks WHERE message=?)',(self.path.removeprefix('/api/context/'),)), 'amendments':self.server.app.store.rows('SELECT * FROM amendments WHERE task IN (SELECT task FROM turn_tasks WHERE message=?)',(self.path.removeprefix('/api/context/'),))})
        files={'/':('index.html','text/html'),'/app.js':('app.js','application/javascript'),'/style.css':('style.css','text/css')}
        if self.path not in files: return self.respond(404,{'error':'Not found'})
        f,t=files[self.path]; return self.respond(200,(ROOT/'web'/f).read_text(),t)
    def do_POST(self):
        if not self.allowed(True): return self.respond(403,{'error':'Same-origin JSON requests only'})
        try:
            n=int(self.headers.get('Content-Length','0'))
            if not 0<n<=20000: raise ValueError('Invalid request size')
            d=json.loads(self.rfile.read(n))
            if not isinstance(d,dict): raise ValueError('Expected JSON object')
            return self.respond(200,self.server.app.post(self.path,d))
        except (ValueError,KeyError,TypeError) as e: return self.respond(400,{'error':str(e)})
        except Exception: return self.respond(500,{'error':'Internal error; no automatic retry'})

def main():
    os.umask(0o077)
    port=int(os.environ.get('PROJECTX_PORT','8765'))
    data_root=Path(os.environ.get('PROJECTX_DATA',str(ROOT/'.data')))
    extractor=None
    if os.environ.get('PROJECTX_LIVE')=='1' and os.environ.get('PROJECTX_BACKEND','gateway')=='gateway':
        from gateway_adapter import GatewayModelAdapter,GatewayWorkerAdapter
        from memory_extractor import ModelMemoryExtractor
        from memory_tool import MemoryTools
        agent=os.environ.get('PROJECTX_AGENT','coding')
        secretary=GatewayModelAdapter(os.environ.get('PROJECTX_SECRETARY_MODEL','openai-pool/gpt-6-astra'),agent)
        worker=GatewayWorkerAdapter(os.environ.get('PROJECTX_MODEL','openai-pool/gpt-6-sol'),agent,memory_tool=MemoryTools(data_root))
        stronger=GatewayModelAdapter(os.environ.get('PROJECTX_ESCALATION_MODEL','openai-pool/gpt-6-sol'),agent)
        extractor=ModelMemoryExtractor(GatewayModelAdapter(os.environ.get('PROJECTX_MEMORY_MODEL',secretary.model),agent))
    else:
        worker=configured();secretary=OpenClawAdapter(os.environ.get('PROJECTX_SECRETARY_MODEL','')) if os.environ.get('PROJECTX_LIVE')=='1' else DisabledAdapter();stronger=None
    app=App(data_root,Orchestrator(secretary,worker,stronger),extractor);app.store.rebuild()
    server=HTTPServer(('127.0.0.1',port),Handler); server.expected_host=f'127.0.0.1:{server.server_port}'; server.app=app
    print(f'PROJECTX → http://{server.expected_host} · {app.adapter.name}',flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close(); app.close()
if __name__=='__main__': main()
