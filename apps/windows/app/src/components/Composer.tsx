import { useState } from "react";
import { command } from "../api";
import { strings } from "../strings";
export function Composer({ convId, act }: { convId: string; act: (task: Promise<void>) => void }) {
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const tooLong = text.length > 60_000;
  return <form className="composer" onSubmit={e => {
    e.preventDefault();
    if (!text.trim() || tooLong || sending) return;
    setSending(true);
    act(command("send_message", { convId, text }).then(() => setText("")).finally(() => setSending(false)));
  }}>
    <label htmlFor="message">{strings.message}</label>
    <textarea id="message" rows={3} value={text} aria-invalid={tooLong} aria-describedby={tooLong ? "message-limit" : undefined} onChange={e => setText(e.target.value)} />
    {tooLong && <p id="message-limit" role="alert">{strings.tooLong}</p>}
    <button disabled={tooLong || !text.trim() || sending} type="submit">{strings.send}</button>
  </form>;
}
