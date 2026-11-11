import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

// Mirrors yorozu-core's Snapshot (core/src/snapshot.rs).
export type Snapshot = {
  pairing: { state: "unpaired" };
  status: string | null;
  notice: { seq: number; text: string } | null;
  list: { convId: string; title: string }[];
  open: {
    convId: string;
    items: { id: string; text: string }[];
    olderMore: boolean;
    marks: string[];
  } | null;
  version: string;
  build: string;
};

export function fetchSnapshot(): Promise<Snapshot> {
  return invoke<Snapshot>("snapshot");
}

/** Calls `callback` whenever the core says its state changed, whatever the scope. Returns the unsubscribe. */
export function onChanged(callback: () => void): () => void {
  const unlisten = listen("changed", callback);
  return () => {
    void unlisten.then((stop) => stop());
  };
}
