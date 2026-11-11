import { command } from "../api";
import { strings } from "../strings";
export function Removed({ reason, act }: { reason: "revoked" | "unreadable"; act: (task: Promise<void>) => void }) {
  return <section className="pairing"><p>{reason === "revoked" ? strings.S8 : strings.S12}</p><button onClick={() => act(command("pair_again"))}>Pair again</button></section>;
}
