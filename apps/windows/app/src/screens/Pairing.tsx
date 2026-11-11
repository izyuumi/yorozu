import { strings } from "../strings";

export function Pairing() {
  return (
    <section className="pairing">
      <h1>{strings.pairingHeading}</h1>
      <label htmlFor="pairing-link">
        {strings.pairingLabel} <code>{strings.pairingCommand}</code>
      </label>
      <textarea id="pairing-link" rows={4} spellCheck={false} autoComplete="off" />
      <button type="button" disabled aria-describedby="pairing-note">
        {strings.pairingButton}
      </button>
      <p id="pairing-note" className="note">
        {strings.pairingNote}
      </p>
    </section>
  );
}
