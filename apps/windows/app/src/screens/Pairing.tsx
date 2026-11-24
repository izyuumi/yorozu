import { useState } from "react";
import { command, type PairingView } from "../api";
import { strings } from "../strings";
import { FingerprintConfirmation, PairLinkForm } from "../components/shared/ClientUI";

export function Pairing({ pairing, act }: { pairing: PairingView; act: (task: Promise<void>) => void }) {
  if (pairing.state === "confirming") return (
    <section className="pairing">
      <h1>{strings.pairingHeading}</h1>
      <FingerprintConfirmation fingerprint={pairing.fingerprint} footer={<><p>{pairing.relayHost}</p><p>{strings.S1}</p></>}
        confirmLabel="Confirm" onPair={() => act(command("confirm_pairing"))}
        onCancel={() => act(command("cancel_pairing"))} />
    </section>
  );
  if (pairing.state === "pairing") return <section className="pairing"><h1>Pairing…</h1><button onClick={() => act(command("cancel_pairing"))}>Cancel</button></section>;
  return <PairingInput act={act} />;
}

function PairingInput({ act }: { act: (task: Promise<void>) => void }) {
  const [link, setLink] = useState("");
  return <section className="pairing">
    <h1>{strings.pairingHeading}</h1>
    <PairLinkForm inputId="pairing-link" rows={4} value={link} continueLabel={strings.pairingButton}
      label={<>{strings.pairingLabel} <code>{strings.pairingCommand}</code></>}
      disabled={!link.trim()} onChange={e => setLink(e.target.value)}
      onContinue={event => { event.preventDefault(); act(command("submit_link", { link })); setLink(""); }} />
  </section>;
}
