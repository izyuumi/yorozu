import { useEffect, useState } from "react";
import { fetchSnapshot, onChanged, type Snapshot } from "./api";
import { Pairing } from "./screens/Pairing";
import { Status } from "./screens/Status";
import { Removed } from "./screens/Removed";
import { strings } from "./strings";
export function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [dismissed, setDismissed] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const act = (task: Promise<void>) => { void task.catch(e => setError(String(e))); };
  useEffect(() => {
    let active = true;
    let request = 0;
    const refresh = () => { const id = ++request; void fetchSnapshot().then(value => { if (active && id === request) setSnapshot(value); }).catch(e => { if (active) setError(String(e)); }); };
    const stop = onChanged(refresh); refresh();
    return () => { active = false; stop(); };
  }, []);
  if (!snapshot) return error ? <p role="alert">{error}</p> : null;
  return <div className="app">
    <main>
      {snapshot.notice && snapshot.notice.seq > dismissed && <button role="status" onClick={() => setDismissed(snapshot.notice!.seq)}>{snapshot.notice.text}</button>}
      {error && <button role="alert" onClick={() => setError(null)}>{error}</button>}
      {snapshot.pairing.state === "removed" ? <Removed reason={snapshot.pairing.reason} act={act} /> : snapshot.pairing.state === "paired" ? <Status snapshot={snapshot} act={act} /> : <>
        <Pairing pairing={snapshot.pairing} act={act} />
        {snapshot.pairing.state === "pairing" && <Status snapshot={snapshot} act={act} />}
      </>}
    </main>
    <footer>{strings.appName} {snapshot.version} ({snapshot.build})</footer>
  </div>;
}
