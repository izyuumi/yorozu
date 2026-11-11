import { useState } from "react";
import { command, type PairingView } from "../api";
import { strings } from "../strings";
export function Pairing({ pairing, act }: { pairing: PairingView; act: (task: Promise<void>) => void }) {
  const [link, setLink] = useState("");
  if (pairing.state === "confirming") return (
    <section className="pairing">
      <h1>{strings.pairingHeading}</h1>
      <p>{pairing.fingerprint}</p><p>{pairing.relayHost}</p><p>{strings.S1}</p>
      <button onClick={() => act(command("confirm_pairing"))}>Confirm</button>
      <button onClick={() => act(command("cancel_pairing"))}>Cancel</button>
    </section>
  );
  if (pairing.state === "pairing") return <section className="pairing"><h1>Pairing…</h1><button onClick={() => act(command("cancel_pairing"))}>Cancel</button></section>;
  return (
    <section className="pairing">
      <h1>{strings.pairingHeading}</h1>
      <form onSubmit={event => { event.preventDefault(); act(command("submit_link", { link })); setLink(""); }}>
        <label htmlFor="pairing-link">
          {strings.pairingLabel} <code>{strings.pairingCommand}</code>
        </label>
        <textarea id="pairing-link" rows={4} spellCheck={false} autoComplete="off" value={link} onChange={e => setLink(e.target.value)} />
        <button type="submit" disabled={!link.trim()}>{strings.pairingButton}</button>
      </form>
    </section>
  );
}
