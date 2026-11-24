import { useEffect, useRef, useState } from "react";
import { command, type PairingView } from "../api";
import { strings } from "../strings";
import { FingerprintConfirmation, PairLinkForm } from "../components/shared/ClientUI";
import { PairingMethods, type PairMethod, type ReceiverCode } from "../components/shared/PairingQr";

export function Pairing({ pairing, deviceCode, act }: { pairing: PairingView; deviceCode?: ReceiverCode | null; act: (task: Promise<void>) => void }) {
  const previousState = useRef<PairingView["state"]>(pairing.state);
  useEffect(() => {
    if (pairing.state === "confirming") document.getElementById("win-confirm-heading")?.focus();
    if (pairing.state === "unpaired" && ["confirming", "pairing"].includes(previousState.current)) {
      document.getElementById("pairing-link")?.focus();
    }
    previousState.current = pairing.state;
  }, [pairing.state]);
  if (pairing.state === "confirming") return (
    <section className="pairing pair-card">
      <FingerprintConfirmation headingId="win-confirm-heading" fingerprint={pairing.fingerprint}
        details={<p>Compare this code with the fingerprint shown on your Mac. Only pair if they match.</p>}
        footer={<><p className="note">Relay: {pairing.relayHost}</p><p className="note">{strings.S1}</p></>}
        confirmLabel="Pair" onPair={() => act(command("confirm_pairing"))}
        onCancel={() => act(command("cancel_pairing"))} />
    </section>
  );
  if (pairing.state === "pairing") return <section className="pairing pair-card"><h1>Pairing…</h1><button onClick={() => act(command("cancel_pairing"))}>Cancel</button></section>;
  return <PairingInput deviceCode={deviceCode} act={act} />;
}

function PairingInput({ deviceCode, act }: { deviceCode?: ReceiverCode | null; act: (task: Promise<void>) => void }) {
  const [link, setLink] = useState("");
  const [pending, setPending] = useState(false);
  const [mode, setMode] = useState<PairMethod>(null);
  const [receiverError, setReceiverError] = useState("");
  const [hadReceiver, setHadReceiver] = useState(false);
  useEffect(() => {
    if (mode === "show" && deviceCode) setHadReceiver(true);
  }, [mode, deviceCode]);
  const startReceiver = () => {
    setReceiverError("");
    setHadReceiver(false);
    return command("start_device_code").catch(error => {
      setReceiverError("Couldn’t open the pairing relay. Try a new QR code.");
      throw error;
    });
  };
  const chooseMethod = (next: PairMethod) => {
    if (mode === "show" && next !== "show") act(command("stop_device_code"));
    setMode(next);
    if (next === "show") act(startReceiver());
  };
  const submit = (raw: string) => command("submit_link", { link: raw.trim() });
  const scan = async (text: string) => {
    try {
      const url = new URL(text.trim());
      const payload = url.protocol === "yorozu:" && url.hostname === "pair" ? url.search :
        url.origin === "https://yorozu.yumi.to" && url.pathname === "/pair" && !url.search ? url.hash.slice(1) : "";
      if (!payload || url.username || url.password || url.port) return false;
      const params = new URLSearchParams(payload);
      if (params.has("v") && params.get("v") !== "3") return false;
      const expiry = Number(params.get("exp"));
      if (Number.isSafeInteger(expiry) && expiry > 0 && expiry <= Date.now()) return "This invite expired. Scan a new code or paste a fresh link.";
      await submit(text);
      return true;
    } catch { return false; }
  };
  return <section className="pairing pair-card">
    <PairingMethods mode={mode} onMode={chooseMethod} onScan={scan} receiver={deviceCode}
      focusPaste={() => document.getElementById("pairing-link")?.focus()}
      receiverError={receiverError || (hadReceiver && !deviceCode ? "This QR code is no longer active." : "")}
      restart={() => act(command("stop_device_code").then(startReceiver))}
      scanHint="Scan a Yorozu client invitation from your Mac or an already-paired device."
      showHint="In Yorozu on an already-paired iPhone or iPad, open Settings → Devices → Add Device and scan this code." />
    {!mode && <PairLinkForm inputId="pairing-link" rows={1} value={link} continueLabel="Continue"
      label="Pairing link" heading="Connect to your Mac" description="Paste the invitation link from your Mac."
      placeholder="Paste an invitation link"
      help={<details className="pair-help"><summary>Need a pairing link?</summary><p>On your Mac, run:</p><code>{strings.pairingCommand}</code></details>}
      disabled={pending || !link.trim()} onChange={e => setLink(e.target.value)}
      onContinue={event => {
        event.preventDefault();
        if (pending || !link.trim()) return;
        setPending(true);
        act(submit(link).finally(() => setPending(false)));
      }} />}
  </section>;
}
