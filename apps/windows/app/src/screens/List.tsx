import { command, type Snapshot } from "../api";
import { strings } from "../strings";
export function List({ conversations, act }: { conversations: Snapshot["list"]; act: (task: Promise<void>) => void }) {
  return <section className="conversations" aria-label={strings.conversations}>
    <header><h1>{strings.conversations}</h1><button onClick={() => act(command("new_conversation"))}>{strings.newConversation}</button></header>
    {conversations.length === 0 && <p>Start a new conversation to send your first message.</p>}
    <ul>{conversations.map(c => <li key={c.convId}><button onClick={() => act(command("open_conversation", { convId: c.convId }))}>{c.title}</button></li>)}</ul>
  </section>;
}
