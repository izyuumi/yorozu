import { useLayoutEffect, useRef } from "react";
import { command, type OpenConv } from "../api";
import { Composer } from "../components/Composer";
import { Message } from "../components/Message";
import { strings } from "../strings";
export function Conversation({ conversation: c, act }: { conversation: OpenConv; act: (task: Promise<void>) => void }) {
  const scroll = useRef<HTMLDivElement>(null);
  const previous = useRef<{ first?: string; last?: string; height: number; bottom: boolean }>({ height: 0, bottom: true });
  useLayoutEffect(() => {
    const node = scroll.current;
    if (!node) return;
    const first = c.items[0]?.id, last = c.items.at(-1)?.id;
    const old = previous.current;
    if (old.first && first !== old.first && last === old.last) node.scrollTop += node.scrollHeight - old.height;
    else if (old.bottom && last !== old.last) node.scrollTop = node.scrollHeight;
    previous.current = { first, last, height: node.scrollHeight, bottom: node.scrollHeight - node.scrollTop - node.clientHeight < 48 };
  }, [c.items]);
  return <section className="conversation" aria-label={c.title}>
    <header><button onClick={() => act(command("open_conversation", { convId: null }))}>← {strings.conversations}</button><h1>{c.title}</h1></header>
    <div className="transcript" ref={scroll} onScroll={e => { const node = e.currentTarget; previous.current.bottom = node.scrollHeight - node.scrollTop - node.clientHeight < 48; }}>
      {c.olderMore && <button onClick={() => act(command("load_older", { convId: c.convId }))}>{strings.loadOlder}</button>}
      <ol aria-label="Messages">{c.items.map(item => <Message key={`${item.kind}:${item.id}`} item={item} convId={c.convId} act={act} />)}</ol>
      {c.typing && <p role="status">{strings.typing}</p>}
    </div>
    <Composer convId={c.convId} act={act} />
  </section>;
}
