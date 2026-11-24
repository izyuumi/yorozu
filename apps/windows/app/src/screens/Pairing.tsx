import { useState } from "react";
import { command, type PairingView } from "../api";
import { strings } from "../strings";
import { FingerprintConfirmation, PairLinkForm } from "../components/shared/ClientUI";

export function Pairing({ pairing, act }: { pairing: PairingView; act: (task: Promise<void>) => void }) {
  if (pairing.state === "confirming") return (
    <section className="pairing pair-card">
      <FingerprintConfirmation fingerprint={pairing.fingerprint}
        details={<p>Compare this code with the fingerprint shown on your Mac. Only pair if they match.</p>}
        footer={<><p className="note">Relay: {pairing.relayHost}</p><p className="note">{strings.S1}</p></>}
        confirmLabel="Pair" onPair={() => act(command("confirm_pairing"))}
        onCancel={() => act(command("cancel_pairing"))} />
    </section>
  );
  if (pairing.state === "pairing") return <section className="pairing pair-card"><h1>Pairing…</h1><button onClick={() => act(command("cancel_pairing"))}>Cancel</button></section>;
  return <PairingInput act={act} />;
}

function PairingInput({ act }: { act: (task: Promise<void>) => void }) {
  const [link, setLink] = useState("");
  const [pending, setPending] = useState(false);
  return <section className="pairing pair-card">
    <PairLinkForm inputId="pairing-link" rows={1} value={link} continueLabel="Continue"
      label="Pairing link" heading="Connect to your Mac" description="Paste the invitation link from your Mac."
      placeholder="Paste an invitation link"
      help={<details className="pair-help"><summary>Need a pairing link?</summary><p>On your Mac, run:</p><code>{strings.pairingCommand}</code></details>}
      disabled={pending || !link.trim()} onChange={e => setLink(e.target.value)}
      onContinue={event => {
        event.preventDefault();
        if (pending || !link.trim()) return;
        setPending(true);
        act(command("submit_link", { link: link.trim() }).finally(() => setPending(false)));
      }} />
  </section>;
}
