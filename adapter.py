"""Harness boundary: generate(context) -> final text; never impersonates success."""
import json, os, subprocess, tempfile, signal
from pathlib import Path
from core import pack
ROOT=Path(__file__).resolve().parent

class AdapterError(Exception): pass
class DisabledAdapter:
    name='offline — no model configured'
    def generate(self,context): raise AdapterError('Live model is off. Start PROJECTX from an ordinary owner terminal with PROJECTX_LIVE=1 to use the configured Gateway. Your message is saved; no fake reply was generated.')
class OpenClawAdapter:
    name='OpenClaw isolated exec (live)'
    def __init__(self,model,runner=None):
        if not model or '/' not in model: raise ValueError('Use provider/model')
        self.model=model; self.name=f'OpenClaw isolated one-shot / {model} (no live steering)'; self.runner=runner or self._run
    def _run(self,args,prompt,cwd):
        p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,cwd=cwd,start_new_session=True)
        try: out,err=p.communicate(prompt,timeout=100)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL); p.communicate(); raise AdapterError('OpenClaw exceeded 100 seconds; process group stopped')
        return p.returncode,out,err
    def generate(self,context):
        # Fresh empty workspace and ephemeral CLI state for every turn. No private session IDs.
        base=ROOT/'.data'/'runs'; base.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=base) as cwd:
            config=json.loads((ROOT/'openclaw.project.json').read_text())
            config['agents']['defaults']['models']={self.model:{'agentRuntime':{'id':'openclaw'}}}
            config_path=Path(cwd)/'config.json';config_path.write_text(json.dumps(config))
            args=['openclaw','agent','exec','--config',str(config_path),'--cwd',cwd,'--model',self.model,'--timeout','80','--json','--message-file','-']
            try: code,out,_=self.runner(args,pack(context),cwd)
            except OSError as e: raise AdapterError('Cannot launch OpenClaw CLI') from e
        try: result=json.loads(out)
        except (ValueError,TypeError): raise AdapterError('OpenClaw returned invalid JSON (diagnostics not exposed)')
        if code or not isinstance(result,dict) or result.get('ok') is not True or result.get('status')!='ok':
            raise AdapterError('OpenClaw failed (authentication, timeout, policy, or provider error). Inspect CLI locally with a synthetic probe; raw diagnostics are not stored.')
        final=result.get('final')
        if not isinstance(final,str) or not final.strip(): raise AdapterError('OpenClaw returned no final text')
        if len(final.encode())>64000: raise AdapterError('OpenClaw response exceeded 64 KB')
        return final

def configured():
    return OpenClawAdapter(os.environ.get('PROJECTX_MODEL','')) if os.environ.get('PROJECTX_LIVE')=='1' else DisabledAdapter()
