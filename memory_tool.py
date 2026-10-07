"""Worker memory tools: selective search and scoped Markdown read/CAS-write."""
import json,sys,sqlite3
from pathlib import Path
from core import Store,pack
from memory_fs import MemoryConflict

SCHEMAS={
 'memory.search':({'topic_id','query'},set()),
 'memory.read':({'path'},{'path'}),
 'memory.write':({'path','markdown','expected_sha256'},{'path','markdown','expected_sha256'}),
}
def invoke(store,request):
    if not isinstance(request,dict) or set(request)-{'tool','arguments'}:raise ValueError('Invalid memory tool request')
    tool=request.get('tool');a=request.get('arguments',{})
    if tool not in SCHEMAS:raise ValueError('Unknown memory tool; no generic filesystem or chat operation is exposed')
    allowed,required=SCHEMAS[tool]
    if not isinstance(a,dict) or set(a)-allowed or not required<=set(a):raise ValueError('Invalid or missing memory tool arguments')
    if tool=='memory.search':
        q=a.get('query','')
        if not isinstance(q,str) or len(q)>200:raise ValueError('Invalid query')
        from memory_extractor import SENSITIVE
        candidates=store.search_memory(a.get('topic_id'),q)
        safe=[m for m in candidates if not SENSITIVE.search(pack(m))]
        return {'results':safe,'withheld':len(candidates)-len(safe)}
    from memory_files import read_file,write_file
    if tool=='memory.read':return read_file(store,a['path'])
    return write_file(store,a['path'],a['markdown'],a['expected_sha256'])

class MemoryTools:
    """Fixed project-root capability passed to the worker adapter, never model-selected."""
    def __init__(self,root):
        self.root=Path(root).resolve()
        if not (self.root/'projectx.sqlite').exists():
            initialized=Store(self.root);initialized.db.close() # Trusted host startup, not a worker operation.
    def __call__(self,request):
        store=None
        try:
            if self.root.is_symlink() or self.root.resolve()!=self.root:raise ValueError('Data root changed')
            store=Store(self.root,memory_tools_only=True)
            return {'ok':True,**invoke(store,request)}
        except MemoryConflict as e:return {'ok':False,'error_code':'conflict','error':str(e)}
        except (ValueError,KeyError,TypeError):return {'ok':False,'error_code':'invalid_memory_operation','error':'Invalid path, Markdown, attribution, size or arguments; no write performed'}
        except OSError:return {'ok':False,'error_code':'filesystem_refusal','error':'Memory boundary or filesystem refused the operation'}
        except sqlite3.Error:return {'ok':False,'error_code':'index_or_database_failure','error':'Memory index/database unavailable; inspect canonical Markdown before retrying'}
        finally:
            if store:store.db.close()

if __name__=='__main__':
    service=MemoryTools(Path(__file__).resolve().parent/'.data')
    while True:
        line=sys.stdin.readline(24001)
        if not line:break
        if len(line.encode())>24000:print(pack({'ok':False,'error':'Request too large'}),flush=True);raise SystemExit(1)
        try:result=service(json.loads(line))
        except (ValueError,TypeError):result={'ok':False,'error':'Invalid JSON request'}
        print(pack(result),flush=True)
