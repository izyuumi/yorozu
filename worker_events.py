"""Project only, committed visible-message projection. Never expose reasoning/tool data."""
import json,re
SECRET=re.compile(r'\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,}|Bearer\s+\S+)|(?:password|api[_ -]?key|access[_ -]?token)\s*[:=]',re.I)
def visible_events(history):
    events=[]
    for m in history.get('messages',[]):
        if not isinstance(m,dict) or m.get('role')!='assistant' or m.get('channel') in ('analysis','reasoning') or m.get('phase') in ('analysis','reasoning'):continue
        origin=m.get('id') or m.get('__openclaw',{}).get('id')
        if not isinstance(origin,str) or not origin:continue # Ignore uncommitted live token snapshots.
        content=m.get('content',[])
        if isinstance(content,str):content=[{'type':'text','text':content}]
        if not isinstance(content,list):continue
        for index,block in enumerate(content):
            if not isinstance(block,dict):continue
            kind=block.get('type');text=''
            if kind=='text':
                signature=block.get('textSignature')
                if isinstance(signature,str) and signature.startswith('{'):
                    try:
                        if json.loads(signature).get('phase') in ('analysis','reasoning'):continue
                    except ValueError:continue
                text=block.get('text','');kind='message'
                if isinstance(text,str):
                    try:structured=json.loads(text)
                    except ValueError:structured=None
                    if isinstance(structured,dict) and 'memory_call' in structured:
                        call=structured['memory_call'];tool=call.get('tool') if isinstance(call,dict) else None
                        tool=tool if tool in ('memory.read','memory.write','memory.search') else 'refused_operation'
                        text='Application memory tool requested: '+tool;kind='tool_metadata'
            elif kind in ('toolCall','tool_use','tool_call'):
                name=block.get('name','')
                if not isinstance(name,str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,100}',name):continue
                text='Tool call recorded: '+name;kind='tool_metadata'
            else:continue # No thinking/reasoning, arguments, outputs, credentials or media.
            if not isinstance(text,str) or not text.strip():continue
            if SECRET.search(text):text='[Visible message withheld: potential credential content]';kind='redacted'
            events.append({'id':f'{origin}:{index}','source_id':origin,'kind':kind,'text':text[:8000],'timestamp':m.get('timestamp'),'source':'gateway.chat.history'})
    return events
