import { useState, useSyncExternalStore } from "react";
import { command } from "../api";
import { strings } from "../strings";
import type { ConversationMemory } from "../screens/Conversation";
import { ComposerFields } from "./shared/ClientUI";

export function Composer({ convId, memory, act }: { convId: string; memory: ConversationMemory; act: (task: Promise<void>) => void }) {
  const text = useSyncExternalStore(listener => {
    const listeners = memory.draftListeners ??= new Set();
    listeners.add(listener);
    return () => { listeners.delete(listener); };
  }, () => memory.draft);
  const update = (value: string) => {
    memory.draft = value;
    memory.draftListeners?.forEach(listener => listener());
  };
  const [sending, setSending] = useState(false);
  const tooLong = text.length > 60_000;
  return <ComposerFields rows={1} label={strings.message} sendLabel={strings.send} value={text}
    disabled={tooLong || !text.trim() || sending} limit={tooLong ? strings.tooLong : undefined}
    onChange={e => update(e.target.value)} onSubmit={e => {
      e.preventDefault();
      if (!text.trim() || tooLong || sending) return;
      setSending(true);
      act(command("send_message", { convId, text }).then(() => { if (memory.draft === text) update(""); }).finally(() => setSending(false)));
    }} />;
}
