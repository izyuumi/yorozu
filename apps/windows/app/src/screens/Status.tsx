import { useState } from "react";
import { command, type Snapshot } from "../api";
import { strings } from "../strings";
export function Status({ snapshot, act }: { snapshot: Snapshot; act: (task: Promise<void>) => void }) {
  const [confirm, setConfirm] = useState(false);
  return <section className="pairing">
    {snapshot.status && <p role="status">{snapshot.status}</p>}
    {snapshot.lastClose && <p className="note">{snapshot.lastClose}</p>}
    {snapshot.updateRequired && <button onClick={() => act(command("retry_connection"))}>Try again</button>}
    {snapshot.pairing.state === "paired" && (confirm ? <div>
      <p>Forget this PC's pairing?</p><p>{strings.S10}</p>
      <button onClick={() => act(command("forget_pairing"))}>Forget pairing</button>
      <button onClick={() => setConfirm(false)}>Cancel</button>
    </div> : <button onClick={() => setConfirm(true)}>Forget</button>)}
  </section>;
}
