import { useState } from "react";
import { command, type Snapshot } from "../api";
import { strings } from "../strings";
import { ForgetAction } from "../components/shared/ClientUI";
export function Status({ snapshot, act }: { snapshot: Snapshot; act: (task: Promise<void>) => void }) {
  const [confirm, setConfirm] = useState(false);
  return <section className="pairing">
    {snapshot.status && <p role="status">{snapshot.status}</p>}
    {snapshot.lastClose && <p className="note">{snapshot.lastClose}</p>}
    {snapshot.updateRequired && <button onClick={() => act(command("retry_connection"))}>Try again</button>}
    {snapshot.pairing.state === "paired" && <div className="device-controls">
      <h3>This PC</h3><p className="note">{confirm ? strings.S10 : "This PC remembers its pairing."}</p>
      {confirm ? <div className="pair-actions">
        <button onClick={() => setConfirm(false)}>Cancel</button>
        <ForgetAction onForget={() => act(command("forget_pairing"))} label="Forget pairing" />
      </div> : <button onClick={() => setConfirm(true)}>Forget this PC</button>}
    </div>}
  </section>;
}
