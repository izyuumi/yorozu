import { useEffect, useState } from "react";
import { fetchSnapshot, onChanged, type Snapshot } from "./api";
import { Pairing } from "./screens/Pairing";
import { strings } from "./strings";

export function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);

  useEffect(() => {
    const refresh = () => void fetchSnapshot().then(setSnapshot);
    refresh();
    return onChanged(refresh);
  }, []);

  if (!snapshot) return null;

  return (
    <div className="app">
      <main>{snapshot.pairing.state === "unpaired" && <Pairing />}</main>
      <footer>
        {strings.appName} {snapshot.version} ({snapshot.build})
      </footer>
    </div>
  );
}
