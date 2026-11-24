import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { command, type OpenConv } from "../api";
import { Composer } from "../components/Composer";
import { Message } from "../components/Message";
import { ChatHeader } from "../components/shared/ClientUI";
import { strings } from "../strings";

export function Conversation({ conversation: c, act, actions, status, navigation }: {
  conversation: OpenConv; act: (task: Promise<void>) => void; actions: ReactNode; status: ReactNode; navigation: ReactNode;
}) {
  const scroll = useRef<HTMLDivElement>(null);
  const previous = useRef<{ first?: string; last?: string; height: number; bottom: boolean; offset: number }>({ height: 0, bottom: true, offset: 0 });
  const [loading, setLoading] = useState(false);
  const [showLatest, setShowLatest] = useState(false);
  const anchor = useRef<{ id: string; top: number } | undefined>(undefined);
  const pageTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(pageTimer.current), []);
  const takeAnchor = () => {
    const viewport = scroll.current;
    if (viewport) {
      const row = Array.from(viewport.querySelectorAll<HTMLElement>("[data-message-anchor]"))
        .find(el => el.getBoundingClientRect().bottom > viewport.getBoundingClientRect().top);
      if (row) anchor.current = { id: row.dataset.messageAnchor!, top: row.getBoundingClientRect().top };
    }
  };
  const finishPage = () => {
    clearTimeout(pageTimer.current);
    pageTimer.current = undefined;
    setLoading(false);
  };
  const loadEarlier = () => {
    if (pageTimer.current || !c.olderMore) return;
    takeAnchor();
    setLoading(true);
    pageTimer.current = setTimeout(finishPage, 10_000);
    act(command("load_older", { convId: c.convId }).catch(error => { finishPage(); throw error; }));
  };
  useLayoutEffect(() => {
    const node = scroll.current;
    if (!node) return;
    const first = c.items[0]?.id, last = c.items.at(-1)?.id;
    const old = previous.current;
    if (old.first && first !== old.first && c.items.some(item => item.id === old.first)) {
      const mark = anchor.current;
      const element = mark && Array.from(node.querySelectorAll<HTMLElement>("[data-message-anchor]")).find(row => row.dataset.messageAnchor === mark.id);
      node.scrollTop += element && mark ? element.getBoundingClientRect().top - mark.top : node.scrollHeight - old.height;
      anchor.current = undefined;
      if (pageTimer.current) finishPage();
    } else if (old.bottom && last !== old.last) node.scrollTop = node.scrollHeight;
    if (!c.olderMore && pageTimer.current) finishPage();
    const distance = node.scrollHeight - node.scrollTop - node.clientHeight;
    previous.current = { first, last, height: node.scrollHeight, bottom: distance < 48, offset: node.scrollTop };
    setShowLatest(distance >= 140);
  }, [c.items, c.olderMore]);
  return <section className="conversation" aria-label={c.title}>
    <ChatHeader title={c.title || "New chat"} status={status} actions={actions} navigation={navigation} />
    <div className="transcript" ref={scroll} tabIndex={0} role="region" aria-label="Message history" onScroll={e => {
      const node = e.currentTarget, top = node.scrollTop;
      if (pageTimer.current) takeAnchor();
      else if (top < previous.current.offset && top < 80) loadEarlier();
      const distance = node.scrollHeight - top - node.clientHeight;
      previous.current.bottom = distance < 48;
      previous.current.offset = top;
      setShowLatest(distance >= 140);
    }}>
      <div className="reading-column">
        {c.olderMore && <div className="history-control"><button disabled={loading} onClick={loadEarlier}>{loading ? "Loading earlier messages…" : "Load earlier messages"}</button></div>}
        {c.items.length === 0 && <div className="empty-chat"><h2>Start a chat</h2><p>Write a message to your Yorozu assistant.</p></div>}
        <ol aria-label="Messages">{c.items.map(item => <Message key={`${item.kind}:${item.id}`} item={item} convId={c.convId} act={act} />)}</ol>
        {c.typing && <p role="status">{strings.typing}</p>}
      </div>
    </div>
    <div className="composer-area"><div className="reading-column">
      {showLatest && <button type="button" className="latest" aria-label="Jump to latest message" onClick={() => {
        if (scroll.current) {
          scroll.current.scrollTop = scroll.current.scrollHeight;
          scroll.current.focus({ preventScroll: true });
        }
      }}>↓</button>}
      <Composer convId={c.convId} act={act} />
    </div></div>
  </section>;
}
