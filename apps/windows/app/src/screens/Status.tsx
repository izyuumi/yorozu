import { useEffect, useRef, useState } from "react";
import { command, type Snapshot } from "../api";
import { ForgetAction } from "../components/shared/ClientUI";
export function Status({ snapshot, act }: { snapshot: Snapshot; act: (task: Promise<void>) => void }) {
  const [confirm, setConfirm] = useState(false);
  const primary = useRef<HTMLButtonElement>(null), cancel = useRef<HTMLButtonElement>(null);
  const restore = useRef(false);
  useEffect(() => {
    if (confirm) cancel.current?.focus();
    else if (restore.current) { primary.current?.focus(); restore.current = false; }
  }, [confirm]);
  return <section className="pairing">
    {snapshot.status && <p role="status">{snapshot.status}</p>}
    {snapshot.lastClose && <p className="note">{snapshot.lastClose}</p>}
    {snapshot.updateRequired && <button onClick={() => act(command("retry_connection"))}>Try again</button>}
    {snapshot.pairing.state === "paired" && <div className="device-controls">
      <h3>This device</h3><p className="note">{confirm ? "This app will need a new invite to reconnect." : "Yorozu remembers this PC’s pairing."}</p>
      <p className="note">Forgetting removes access on this PC only. To revoke access on the host, remove this PC in Devices on an already-paired device.</p>
      {confirm ? <div className="pair-actions">
        <button ref={cancel} onClick={() => { restore.current = true; setConfirm(false); }}>Cancel</button>
        <ForgetAction onForget={() => act(command("forget_pairing"))} label="Forget pairing" />
      </div> : <button ref={primary} onClick={() => setConfirm(true)}>Forget this device</button>}
    </div>}
  </section>;
}
