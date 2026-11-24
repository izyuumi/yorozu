import { useEffect, useRef, useState } from "react";
import { command, fetchSnapshot, onChanged, type Snapshot } from "./api";
import { Pairing } from "./screens/Pairing";
import { Status } from "./screens/Status";
import { Removed } from "./screens/Removed";
import { List } from "./screens/List";
import { Conversation, type ConversationMemory } from "./screens/Conversation";
import { ChatHeader, ClientIcon } from "./components/shared/ClientUI";
import "./components/chat.css";
import { strings } from "./strings";

export function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [dismissed, setDismissed] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const mobileChats = useRef<HTMLDialogElement>(null);
  const previousPairing = useRef<Snapshot["pairing"]["state"] | undefined>(undefined);
  const conversationMemory = useRef(new Map<string, ConversationMemory>());
  const settings = useRef<HTMLDialogElement>(null);
  const [settingsSession, setSettingsSession] = useState(0);
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
  useEffect(() => {
    if (snapshot && snapshot.pairing.state !== "paired") conversationMemory.current.clear();
    if (previousPairing.current === "paired" && snapshot?.pairing.state === "unpaired") document.getElementById("pairing-link")?.focus();
    previousPairing.current = snapshot?.pairing.state;
  }, [snapshot?.pairing.state]);
  useEffect(() => {
    const width = matchMedia("(max-width: 45rem)");
    const closeOnWide = () => { if (!width.matches) mobileChats.current?.close(); };
    width.addEventListener("change", closeOnWide);
    return () => width.removeEventListener("change", closeOnWide);
  }, []);
  if (!snapshot) return <p className="app-opening" role={error ? "alert" : "status"}>{error || "Opening Yorozu…"}</p>;
  const actions = <button className="icon-button" aria-label="Settings" title="Settings" aria-haspopup="dialog" onClick={() => { setSettingsSession(value => value + 1); settings.current?.showModal(); }}><ClientIcon name="settings" /></button>;
  const status = <p role="status">{snapshot.status || "Connecting…"}</p>;
  const navigation = <button className="icon-button mobile-chats-toggle" aria-label="Show chats"
    aria-haspopup="dialog" aria-controls="win-mobile-chats" onClick={() => mobileChats.current?.showModal()}><ClientIcon name="chats" /></button>;
  let memory = snapshot.open && conversationMemory.current.get(snapshot.open.convId);
  if (snapshot.open && !memory) {
    memory = { draft: "" };
    conversationMemory.current.set(snapshot.open.convId, memory);
  }
  return <div className="app">
    <main>
      {snapshot.notice && snapshot.notice.seq > dismissed && <div className="app-notice"><p role="status">{snapshot.notice.text}</p><button aria-label="Dismiss status" onClick={() => setDismissed(snapshot.notice!.seq)}>×</button></div>}
      {error && <div className="app-notice"><p role="alert">{error}</p><button aria-label="Dismiss error" onClick={() => setError(null)}>×</button></div>}
      {snapshot.pairing.state === "removed" ? <Removed reason={snapshot.pairing.reason} act={act} /> : snapshot.pairing.state === "paired" ? <>
        <div className="chat">
          <aside id="win-sidebar">
            <List conversations={snapshot.list} activeId={snapshot.open?.convId} act={act} />
          </aside>
          <div className="chat-content">
            {snapshot.open && memory ? <Conversation key={snapshot.open.convId} conversation={snapshot.open} memory={memory} act={act} actions={actions} status={status} navigation={navigation} /> :
              <section className="conversation">
                <ChatHeader title="Chats" navigation={navigation} status={status} actions={actions} />
                <div className="empty-chat"><h2>Start a chat</h2><p>Pick a recent conversation or start a new one.</p>
                  <button className="primary-button" onClick={() => act(command("new_conversation"))}>New chat</button>
                </div>
              </section>}
          </div>
        </div>
        <dialog ref={mobileChats} id="win-mobile-chats" aria-labelledby="windows-chats">
          <header><h2 id="windows-chats">Chats</h2><form method="dialog"><button aria-label="Close chats" className="icon-button">×</button></form></header>
          <List conversations={snapshot.list} activeId={snapshot.open?.convId} act={task => { mobileChats.current?.close(); act(task); }} />
        </dialog>
        <dialog ref={settings} className="settings-dialog" aria-labelledby="windows-settings">
          <header><h2 id="windows-settings">Settings</h2><form method="dialog"><button aria-label="Close" className="icon-button">×</button></form></header>
          <h3>Connection</h3>
          <Status key={settingsSession} snapshot={snapshot} act={act} />
          <p className="note">{strings.appName} {snapshot.version} ({snapshot.build})</p>
        </dialog>
      </> : <>
        <div className="entry-brand client-brand"><span aria-hidden="true" />Yorozu</div>
        <Pairing pairing={snapshot.pairing} deviceCode={snapshot.deviceCode} act={act} />
        {snapshot.pairing.state === "pairing" && <Status snapshot={snapshot} act={act} />}
      </>}
    </main>
  </div>;
}
