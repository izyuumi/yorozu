import { useEffect, useRef, useState } from "react";
import { command, fetchSnapshot, onChanged, type Snapshot } from "./api";
import { Pairing } from "./screens/Pairing";
import { Status } from "./screens/Status";
import { Removed } from "./screens/Removed";
import { List } from "./screens/List";
import { Conversation } from "./screens/Conversation";
import { ChatHeader, ClientIcon } from "./components/shared/ClientUI";
import "./components/chat.css";
import { strings } from "./strings";

export function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [dismissed, setDismissed] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [showChats, setShowChats] = useState(false);
  const settings = useRef<HTMLDialogElement>(null);
  const act = (task: Promise<void>) => { void task.catch(e => setError(String(e))); };
  useEffect(() => {
    let active = true;
    let request = 0;
    const refresh = () => { const id = ++request; void fetchSnapshot().then(value => {
      if (active && id === request) setSnapshot(value);
    }).catch(e => { if (active) setError(String(e)); }); };
    const stop = onChanged(refresh); refresh();
    return () => { active = false; stop(); };
  }, []);
  if (!snapshot) return <p className="app-opening" role={error ? "alert" : "status"}>{error || "Opening Yorozu…"}</p>;
  const actions = <button className="icon-button" aria-label="Settings" title="Settings" aria-haspopup="dialog" onClick={() => settings.current?.showModal()}><ClientIcon name="settings" /></button>;
  const status = <p role="status">{snapshot.status || "Connecting…"}</p>;
  const navigation = <button className="icon-button mobile-chats-toggle" aria-label={showChats ? "Hide chats" : "Show chats"}
    aria-expanded={showChats} aria-controls="win-sidebar" onClick={() => setShowChats(!showChats)}><ClientIcon name="chats" /></button>;
  return <div className="app">
    <main>
      {snapshot.notice && snapshot.notice.seq > dismissed && <button className="app-notice" role="status" onClick={() => setDismissed(snapshot.notice!.seq)}>{snapshot.notice.text}</button>}
      {error && <button className="app-notice" role="alert" onClick={() => setError(null)}>{error}</button>}
      {snapshot.pairing.state === "removed" ? <Removed reason={snapshot.pairing.reason} act={act} /> : snapshot.pairing.state === "paired" ? <>
        <div className="chat">
          <aside id="win-sidebar" className={showChats ? "shown" : ""}>
            <List conversations={snapshot.list} activeId={snapshot.open?.convId} act={task => { setShowChats(false); act(task); }} />
          </aside>
          <div className="chat-content">
            {snapshot.open ? <Conversation key={snapshot.open.convId} conversation={snapshot.open} act={act} actions={actions} status={status} navigation={navigation} /> :
              <section className="conversation">
                <ChatHeader title="Chats" navigation={navigation} status={status} actions={actions} />
                <div className="empty-chat"><h2>Start a chat</h2><p>Pick a recent conversation or start a new one.</p>
                  <button className="primary-button" onClick={() => act(command("new_conversation"))}>New chat</button>
                </div>
              </section>}
          </div>
        </div>
        <dialog ref={settings} className="settings-dialog" aria-labelledby="windows-settings">
          <header><h2 id="windows-settings">Settings</h2><form method="dialog"><button aria-label="Close" className="icon-button">×</button></form></header>
          <h3>Connection</h3>
          <Status snapshot={snapshot} act={act} />
          <p className="note">{strings.appName} {snapshot.version} ({snapshot.build})</p>
        </dialog>
      </> : <>
        <div className="entry-brand client-brand"><span aria-hidden="true" />Yorozu</div>
        <Pairing pairing={snapshot.pairing} act={act} />
        {snapshot.pairing.state === "pairing" && <Status snapshot={snapshot} act={act} />}
      </>}
    </main>
  </div>;
}
