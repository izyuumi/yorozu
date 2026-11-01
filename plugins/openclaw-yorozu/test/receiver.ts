// The plugin's upload receiver over stdio for ResumeBenchTests: one JSON event per line in, answers out.
// Usage: node receiver.ts <spoolDir>; stored files go to <spoolDir>/../stored/<attachmentId>.
// Without an argument (as `node --test` loads it) it does nothing.
import fs from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { receiveChunk, receiveStatus, Spool, type Receiver } from "../src/spool.ts";

async function serve(dir: string): Promise<void> {
  const storeDir = path.join(dir, "..", "stored");
  await fs.mkdir(storeDir, { recursive: true });
  const r: Receiver = {
    spool: new Spool({ dir, chunkBytes: 160 * 1024 }),
    maxBytes: 1024 * 1024 * 1024,
    isStored: (id) => fs.access(path.join(storeDir, id)).then(() => true, () => false),
    store: ({ meta, path: file }) => fs.copyFile(file, path.join(storeDir, meta.id)),
  };
  await r.spool.sweep();
  let queue = Promise.resolve();
  for await (const line of createInterface({ input: process.stdin })) {
    const { kind, data } = JSON.parse(line);
    const answer = kind === "upload" ? receiveChunk(r, data) : kind === "upload_status" ? receiveStatus(r, data) : Promise.resolve([]);
    queue = queue.then(async () => {
      for (const event of await answer) process.stdout.write(JSON.stringify(event) + "\n");
    });
  }
  await queue;
}

if (process.argv[2]) await serve(process.argv[2]);
