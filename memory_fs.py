"""Small POSIX memory-directory lock and no-follow filesystem boundary."""
import contextlib,fcntl,functools,os,re,stat,threading
from pathlib import PurePosixPath
LOCK=threading.RLock()
LOCAL=threading.local()
class MemoryConflict(ValueError):pass

@contextlib.contextmanager
def memory_lock(root):
    key=str(root.absolute())
    with LOCK:
        held=getattr(LOCAL,'held',{})
        if key in held:
            yield held[key];return
        fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:
            fcntl.flock(fd,fcntl.LOCK_EX)
            LOCAL.held={**held,key:fd}
            yield fd
        finally:
            LOCAL.held=held;fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)

def guarded(method):
    @functools.wraps(method)
    def call(self,*args,**kwargs):
        with memory_lock(self.memory):return method(self,*args,**kwargs)
    return call

def parts(path):
    if not isinstance(path,str) or not path or len(path)>500 or '\\' in path:raise ValueError('Invalid relative memory path')
    raw=path.split('/')
    if any(p in ('','.','..') or any(ord(c)<32 or ord(c)==127 for c in p) for p in raw) or not path.endswith('.md'):raise ValueError('Only relative Markdown paths inside memory are allowed')
    return raw

@contextlib.contextmanager
def parent_fd(root_fd,path):
    components=parts(path);fd=os.dup(root_fd)
    try:
        for component in components[:-1]:
            new=os.open(component,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd);os.close(fd);fd=new
        yield fd,components[-1]
    finally:os.close(fd)

def read_at(parent,name):
    try:fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
    except FileNotFoundError:return None
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_size>12000:raise ValueError('Unsafe or oversized memory file')
        data=b''
        while len(data)<=12000:
            chunk=os.read(fd,12001-len(data))
            if not chunk:break
            data+=chunk
        if len(data)>12000:raise ValueError('Oversized memory file')
        return data
    finally:os.close(fd)
