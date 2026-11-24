import { command, type Snapshot } from "../api";
export function List({ conversations, activeId, act }: { conversations: Snapshot["list"]; activeId?: string; act: (task: Promise<void>) => void }) {
  return <nav className="conversations" aria-label="Conversations">
    <div className="client-brand"><span aria-hidden="true" />Yorozu</div>
    <button className="new-chat" onClick={() => act(command("new_conversation"))}><span aria-hidden="true">＋</span> New chat</button>
    <h2>Recent chats</h2>
    {conversations.length === 0 && <p>No chats yet.</p>}
    <ul>{conversations.map(c => <li key={c.convId}><button aria-current={activeId === c.convId ? "true" : undefined}
      title={c.title} onClick={() => act(command("open_conversation", { convId: c.convId }))}>{c.title || "Untitled chat"}</button></li>)}</ul>
  </nav>;
}
