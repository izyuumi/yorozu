import { createHash } from "node:crypto";
import { closeSync, constants, lstatSync, mkdirSync, openSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { safeAgentPath, validAgentId } from "./agent-scope.js";

export interface WorkerMemoryCapability {
  read(ownerId: string, key: string): string | undefined;
  write(key: string, body: string, operationId: string): void;
  search(ownerId: string, query: string): Array<{ key: string; body: string }>;
  grant(toAgentId: string, key: string, operationId: string): void;
  revoke(toAgentId: string, key: string, operationId: string): void;
}

function text(value: unknown, max: number, empty = false): asserts value is string {
  if (typeof value !== "string" || (!empty && !value.length) || Buffer.byteLength(value) > max || value.includes("\0"))
    throw new Error("Invalid memory input");
}
function key(value: unknown): asserts value is string {
  text(value, 128);
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(value) || ["__proto__", "constructor", "prototype"].includes(value))
    throw new Error("Invalid memory key");
}

/** Host-owned canonical SQL, never a harness filesystem capability. Limits are
 * intentionally finite: 256 notes/owner, 16 KiB/note, 4096 grants/owner,
 * 10000 durable operation receipts/owner, 64 MiB database, 64 search results.
 * Receipts are never evicted: exhaustion fails closed rather than enabling replay.
 * The private directory must also be denied by the host's process sandbox;
 * path checks are not an openat/OS isolation guarantee against same-UID races.
 */
export class WorkerMemory {
  #db: DatabaseSync;
  #root: string;
  #file: string;
  #registered: (agentId: string) => boolean;
  #closed = false;
  #identity: string;
  #rootIdentity: string;

  constructor(root: string, registered: (agentId: string) => boolean) {
    this.#registered = registered;
    this.#root = safeAgentPath(root);
    mkdirSync(this.#root, { recursive: true, mode: 0o700 });
    this.#rootIdentity = this.#check(this.#root, true);
    this.#file = join(this.#root, "worker-memory.sqlite");
    safeAgentPath(this.#file);
    let created = false;
    try {
      const fd = openSync(this.#file, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
      closeSync(fd); created = true;
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    this.#identity = this.#check(this.#file, false);
    if (!created && lstatSync(this.#file).size === 0) throw new Error("Corrupt empty memory database");
    this.#files();
    this.#db = new DatabaseSync(this.#file);
    try {
      this.#db.exec(`PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE;
        PRAGMA synchronous=FULL; PRAGMA busy_timeout=1000; PRAGMA max_page_count=16384;`);
      const integrity = this.#db.prepare("PRAGMA quick_check").all();
      if (integrity.length !== 1 || Object.values(integrity[0])[0] !== "ok") throw new Error("Corrupt memory database");
      const schema = [
        "CREATE TABLE notes(owner TEXT NOT NULL, key TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(owner,key)) STRICT",
        "CREATE TABLE grants(owner TEXT NOT NULL, key TEXT NOT NULL, reader TEXT NOT NULL, PRIMARY KEY(owner,key,reader), FOREIGN KEY(owner,key) REFERENCES notes(owner,key)) STRICT",
        "CREATE TABLE operations(owner TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(owner,id)) STRICT",
      ];
      if (created) this.#db.exec(`BEGIN IMMEDIATE; ${schema.join(";")}; PRAGMA user_version=1; COMMIT;`);
      const version = this.#db.prepare("PRAGMA user_version").get();
      const actual = this.#db.prepare("SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name").all().map(row => row.sql);
      if (version?.user_version !== 1 || JSON.stringify(actual) !== JSON.stringify([schema[1], schema[0], schema[2]])
        || this.#db.prepare("PRAGMA foreign_key_check").all().length
        || this.#db.prepare("PRAGMA page_size").get()?.page_size !== 4096)
        throw new Error("Invalid memory schema");
    } catch (error) { this.#db.close(); throw error; }
  }

  #check(path: string, directory: boolean): string {
    safeAgentPath(path, true);
    const s = lstatSync(path);
    if ((directory ? !s.isDirectory() : !s.isFile() || s.nlink !== 1)
      || (s.mode & 0o777) !== (directory ? 0o700 : 0o600)
      || (!directory && s.size > 64 * 1024 * 1024)
      || (process.getuid && s.uid !== process.getuid())) throw new Error("Unsafe memory file");
    return `${s.dev}:${s.ino}`;
  }
  #files(): void {
    if (this.#check(this.#root, true) !== this.#rootIdentity || this.#check(this.#file, false) !== this.#identity)
      throw new Error("Memory file identity changed");
    for (const suffix of ["-journal", "-wal", "-shm"]) {
      try { lstatSync(this.#file + suffix); this.#check(this.#file + suffix, false); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    }
  }
  #agent(id: string): void {
    if (!validAgentId(id) || this.#registered(id) !== true) throw new Error("Unregistered memory agent");
  }
  #begin(agent: string): void {
    if (this.#closed) throw new Error("Memory closed");
    this.#agent(agent); this.#files();
  }
  #mutation(agent: string, operationId: string, payload: string[], action: () => void): void {
    this.#begin(agent); text(operationId, 128);
    const digest = createHash("sha256").update(JSON.stringify(payload)).digest("hex");
    this.#db.exec("BEGIN IMMEDIATE");
    try {
      const old = this.#db.prepare("SELECT digest FROM operations WHERE owner=? AND id=?").get(agent, operationId);
      if (old) {
        if (old.digest !== digest) throw new Error("Conflicting memory operation ID");
      } else {
        this.#limit("operations", agent, 10000);
        action();
        this.#db.prepare("INSERT INTO operations VALUES(?,?,?)").run(agent, operationId, digest);
      }
      this.#db.exec("COMMIT");
    } catch (error) { this.#db.exec("ROLLBACK"); throw error; }
  }
  #limit(table: "notes" | "grants" | "operations", owner: string, limit: number): void {
    // Table identifier is exclusively a host constant, never model input.
    const row = this.#db.prepare(`SELECT count(*) AS n FROM ${table} WHERE owner=?`).get(owner)!;
    if (Number(row.n) >= limit) throw new Error("Memory capacity exceeded");
  }
  bind(agentId: string): WorkerMemoryCapability {
    this.#begin(agentId);
    const share = (to: string, note: string, op: string, grant: boolean): void => {
      this.#agent(to); key(note);
      this.#mutation(agentId, op, [grant ? "grant" : "revoke", to, note], () => {
        if (grant) {
          if (!this.#db.prepare("SELECT 1 FROM notes WHERE owner=? AND key=?").get(agentId, note)) throw new Error("Unknown memory note");
          if (!this.#db.prepare("SELECT 1 FROM grants WHERE owner=? AND key=? AND reader=?").get(agentId, note, to)) {
            this.#limit("grants", agentId, 4096);
            this.#db.prepare("INSERT INTO grants VALUES(?,?,?)").run(agentId, note, to);
          }
        } else this.#db.prepare("DELETE FROM grants WHERE owner=? AND key=? AND reader=?").run(agentId, note, to);
      });
    };
    // Frozen null-prototype closures: .call(), prototype changes and forged `this`
    // cannot select another identity. Only trusted host code receives bind().
    return Object.freeze(Object.assign(Object.create(null), {
      read: (owner: string, note: string): string | undefined => {
        this.#begin(agentId); this.#agent(owner); key(note);
        const row = this.#db.prepare(`SELECT body FROM notes n WHERE owner=? AND key=?
          AND (owner=? OR EXISTS(SELECT 1 FROM grants g WHERE g.owner=n.owner AND g.key=n.key AND g.reader=?))`).get(owner, note, agentId, agentId);
        if (!row) {
          if (owner !== agentId) throw new Error("Memory access denied");
          return undefined;
        }
        text(row.body, 16384, true); return row.body;
      },
      write: (note: string, body: string, op: string): void => {
        key(note); text(body, 16384, true);
        this.#mutation(agentId, op, ["write", note, body], () => {
          if (!this.#db.prepare("SELECT 1 FROM notes WHERE owner=? AND key=?").get(agentId, note)) this.#limit("notes", agentId, 256);
          this.#db.prepare("INSERT INTO notes VALUES(?,?,?) ON CONFLICT(owner,key) DO UPDATE SET body=excluded.body").run(agentId, note, body);
        });
      },
      search: (owner: string, query: string): Array<{ key: string; body: string }> => {
        this.#begin(agentId); this.#agent(owner); text(query, 256, true);
        if (owner !== agentId && !this.#db.prepare("SELECT 1 FROM grants WHERE owner=? AND reader=?").get(owner, agentId)) throw new Error("Memory access denied");
        const rows = this.#db.prepare(`SELECT key,body FROM notes n WHERE owner=?
          AND (?=owner OR EXISTS(SELECT 1 FROM grants g WHERE g.owner=n.owner AND g.key=n.key AND g.reader=?))
          AND (instr(body,?)>0 OR instr(key,?)>0) ORDER BY key LIMIT 64`).all(owner, agentId, agentId, query, query);
        return rows.map(row => { key(row.key); text(row.body, 16384, true); return { key: row.key, body: row.body }; });
      },
      grant: (to: string, note: string, op: string) => share(to, note, op, true),
      revoke: (to: string, note: string, op: string) => share(to, note, op, false),
    })) as WorkerMemoryCapability;
  }
  close(): void { if (!this.#closed) { this.#db.close(); this.#closed = true; } }
}
