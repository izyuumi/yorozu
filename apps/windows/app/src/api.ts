import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
export type PairingView =
  | { state: "unpaired" | "pairing" | "paired" }
  | { state: "confirming"; fingerprint: string; relayHost: string }
  | { state: "removed"; reason: "revoked" | "unreadable" };
export type Mark = { state: "queued" | "sent" | "delivered" | "read" } | { state: "failed"; reason: string };
export type Item = { id: string; kind: "user" | "agent" | "tools" | "reset"; text: string; tools: {callId:string;name:string;status:string}[]; mark: Mark | null; runFailed: boolean };
export type OpenConv = { convId: string; title: string; items: Item[]; olderMore: boolean; typing: boolean };
export type Snapshot = {
  pairing: PairingView;
  status: string | null;
  lastClose?: string;
  updateRequired?: boolean;
  notice: { seq: number; text: string } | null;
  list: { convId: string; title: string }[];
  open: OpenConv | null;
  version: string;
  build: string;
};
export const fetchSnapshot = () => invoke<Snapshot>("snapshot");
export type Command = "submit_link" | "confirm_pairing" | "cancel_pairing" | "forget_pairing" | "pair_again" | "retry_connection" | "open_conversation" | "new_conversation" | "load_older" | "send_message" | "retry_message";
export const command = (name: Command, args?: { link?: string; convId?: string | null; text?: string; messageId?: string }) => invoke<void>(name, args);
export function onChanged(callback: () => void): () => void {
  let active = true;
  const unlisten = listen("changed", callback).then(stop => { if (active) callback(); return stop; });
  return () => { active = false; void unlisten.then(stop => stop()); };
}
