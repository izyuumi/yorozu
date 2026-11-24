import { useState } from "react";
import { command } from "../api";
import { strings } from "../strings";
import { ComposerFields } from "./shared/ClientUI";

export function Composer({ convId, act }: { convId: string; act: (task: Promise<void>) => void }) {
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const tooLong = text.length > 60_000;
  return <ComposerFields rows={3} label={strings.message} sendLabel={strings.send} value={text}
    disabled={tooLong || !text.trim() || sending} limit={tooLong ? strings.tooLong : undefined}
    onChange={e => setText(e.target.value)} onSubmit={e => {
      e.preventDefault();
      if (!text.trim() || tooLong || sending) return;
      setSending(true);
      act(command("send_message", { convId, text }).then(() => setText("")).finally(() => setSending(false)));
    }} />;
}
