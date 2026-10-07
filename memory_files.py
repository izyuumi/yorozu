"""Worker-directed Markdown file reads/CAS writes, confined to Store.memory."""
import hashlib,json,os,re,uuid
from datetime import datetime,timezone
from core import pack,memory_labels
from memory_fs import memory_lock,parent_fd,read_at,MemoryConflict
from memory_extractor import PERSONAL,KNOWLEDGE,REPORTED,SENSITIVE,TENTATIVE

def digest(data):return hashlib.sha256(data).hexdigest()

def read_file(store,path):
    with memory_lock(store.memory) as root:
        with parent_fd(root,path) as (parent,name):
            data=read_at(parent,name)
            if data is None:raise ValueError('Memory file not found')
            try:text=data.decode('utf-8')
            except UnicodeError:raise ValueError('Memory file is not UTF-8')
            if SENSITIVE.search(text):raise ValueError('Potential credential content withheld')
            return {'path':path,'sha256':digest(data),'markdown':text}

def validate(store,path,markdown,old):
    if not isinstance(markdown,str) or not markdown or len(markdown.encode())>12000:raise ValueError('Markdown must be 1–12000 UTF-8 bytes')
    if SENSITIVE.search(markdown):raise ValueError('Potential credential content refused')
    try:
        header,body=markdown.split('\n\n',1);meta=json.loads(header)
        if not isinstance(meta,dict):raise ValueError()
        identifier=str(uuid.UUID(meta['id']))
        if meta['id']!=identifier or path.split('/')[-1]!=identifier+'.md':raise ValueError()
        if not isinstance(meta['title'],str) or not 1<=len(meta['title'])<=120:raise ValueError()
        if meta.get('topic') is not None and (not isinstance(meta['topic'],str) or len(meta['topic'])>120):raise ValueError()
        if not body.strip() or len(body.encode())>8000:raise ValueError()
        sources=meta.get('sources',[])
        if not isinstance(sources,list) or len(sources)>16 or any(not isinstance(x,str) or str(uuid.UUID(x))!=x for x in sources):raise ValueError()
        if any(not store.rows('SELECT id FROM messages WHERE id=?',(source,)) for source in sources):raise ValueError('Unknown source message ID')
        kind=meta.get('knowledge_type','generated_analysis');who=meta.get('attribution','assistant');status=meta.get('epistemic_status','unverified')
        if kind not in KNOWLEDGE or who not in ('user','assistant','quoted_source') or status not in ('user_stated','unverified','tentative'):raise ValueError()
        quote=meta.get('evidence')
        originals=[r for source in sources for r in store.rows('SELECT body,role FROM messages WHERE id=?',(source,))]
        if quote is not None and (not isinstance(quote,str) or not quote.strip() or not any(quote in r['body'] for r in originals)):raise ValueError('Unsupported source quote')
        if who=='user':
            if not quote or not any(r['role']=='user' and quote in r['body'] and not REPORTED.search(r['body']) for r in originals):raise ValueError('Direct user provenance required')
        if kind in PERSONAL:
            if who!='user' or status!='user_stated' or TENTATIVE.search(quote or ''):raise ValueError()
        elif status=='user_stated':raise ValueError()
        if kind=='source_claim' and who!='quoted_source':raise ValueError()
        if kind=='generated_analysis' and who!='assistant':raise ValueError()
        if who=='quoted_source' and kind not in ('source_claim','tentative_hypothesis'):raise ValueError()
        if kind=='tentative_hypothesis' and status!='tentative':raise ValueError()
        if quote and TENTATIVE.search(quote) and status!='tentative':raise ValueError()
        now=datetime.now(timezone.utc).isoformat()
        previous=json.loads(old.decode('utf-8').split('\n\n',1)[0]) if old is not None else None
        if previous and previous['id']!=identifier:raise ValueError()
        lineage=previous.get('lineage',[]) if previous else []
        if not isinstance(lineage,list) or any(not isinstance(entry,dict) for entry in lineage):raise ValueError('Invalid existing lineage; nothing overwritten')
        lineage=list(lineage)
        if previous:
            lineage.append({'body':old.decode('utf-8').split('\n\n',1)[1],'sources':previous.get('sources',[]),'evidence':previous.get('evidence'),'replaced_at':now,'prior_sha256':digest(old),**memory_labels(previous)})
        # The worker chooses the entire Markdown body. Protected identity/audit
        # fields cannot impersonate an owner edit or erase previous lineage.
        meta.update(id=identifier,kind='worker_edit',knowledge_type=kind,attribution=who,epistemic_status=status,origin_role='user' if who=='user' else 'assistant',source_kind='worker_memory_tool',sources=sources,lineage=lineage,last_editor='worker',updated_at=now,created_at=previous.get('created_at',now) if previous else now)
        data=(pack(meta)+'\n\n'+body).encode('utf-8')
        if len(data)>12000:raise ValueError('Memory plus preserved lineage exceeds 12000 bytes')
        return data,identifier
    except (KeyError,TypeError,json.JSONDecodeError,UnicodeError):raise ValueError('Invalid canonical Markdown header/provenance')

def write_file(store,path,markdown,expected_sha256):
    if expected_sha256 is not None and (not isinstance(expected_sha256,str) or not re.fullmatch(r'[0-9a-f]{64}',expected_sha256)):raise ValueError('Expected SHA-256 or explicit null for creation')
    with memory_lock(store.memory) as root:
        with parent_fd(root,path) as (parent,name):
            old=read_at(parent,name)
            if old is not None and SENSITIVE.search(old.decode('utf-8')):raise ValueError('Potential credential content refused; owner memory maintenance required')
            actual=digest(old) if old is not None else None
            if actual!=expected_sha256:raise MemoryConflict('Memory changed or creation target exists; read current file and reconcile. Nothing overwritten.')
            if old is not None and old.decode('utf-8')==markdown:
                store.rebuild();return {'path':path,'sha256':actual,'changed':False,'indexed':True}
            data,identifier=validate(store,path,markdown,old)
            store.rebuild() # Fail before editing if another canonical file is malformed.
            duplicate=store.rows('SELECT path FROM memory_index WHERE id=?',(identifier,))
            if duplicate and duplicate[0]['path']!=path:raise ValueError('Memory ID already belongs to another path')
            temp='.projectx-'+str(uuid.uuid4())+'.tmp'
            fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=parent)
            durability_warning=None
            try:
                with os.fdopen(fd,'wb') as out:out.write(data);out.flush();os.fsync(out.fileno())
                # Recheck even while the cooperative app/CLI writer lock is held.
                latest=read_at(parent,name)
                if (digest(latest) if latest is not None else None)!=actual:raise MemoryConflict('Memory changed during edit; nothing overwritten')
                os.replace(temp,name,src_dir_fd=parent,dst_dir_fd=parent)
                try:os.fsync(parent)
                except OSError:durability_warning='Atomic replacement succeeded; directory fsync was unavailable'
            finally:
                try:os.unlink(temp,dir_fd=parent)
                except FileNotFoundError:pass
            result={'path':path,'id':identifier,'sha256':digest(data),'changed':True,'indexed':True}
            if durability_warning:result['durability_warning']=durability_warning
            try:store.rebuild()
            except Exception:result.update(indexed=False,index_error='Markdown saved; derived index refresh failed. Explicit rebuild required; do not replay the write.')
            return result
