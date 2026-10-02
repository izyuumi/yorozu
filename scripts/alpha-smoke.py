#!/usr/bin/env python3
"""Real alpha JSONL acceptance, bounded to a new temporary fixture workspace."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import uuid


class Host:
    def __init__(self, args, profile):
        env = dict(os.environ, YOROZU_STATE_DIR=str(profile / "legacy-unused"),
                   YOROZU_MEMORY_DIR=str(profile / "memory-unused"))
        self.process = subprocess.Popen([str(args.host), str(profile), str(args.node), str(args.worker)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, env=env)
        self.frames = []
        self.incoming = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            try:
                self.incoming.put(json.loads(line))
            except ValueError:
                self.incoming.put({"invalidFrame": True})
        self.incoming.put({"hostExited": True})

    def send(self, op, **params):
        request_id = str(uuid.uuid4())
        self.process.stdin.write(json.dumps({"version": 1, "id": request_id, "op": op, **params}) + "\n")
        self.process.stdin.flush()
        return request_id

    def until(self, predicate, timeout=120):
        for frame in self.frames:
            if predicate(frame):
                return frame
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                frame = self.incoming.get(timeout=max(.01, deadline - time.monotonic()))
            except queue.Empty as error:
                raise TimeoutError("alpha event wait timed out") from error
            self.frames.append(frame)
            assert frame.get("version") == 1, "invalid protocol or unexpected host exit"
            if predicate(frame):
                return frame
        raise TimeoutError("alpha acceptance timed out")

    def request(self, op, **params):
        deadline = time.monotonic() + 5
        while True:
            request_id = self.send(op, **params)
            result = self.until(lambda f: f.get("id") == request_id, 15)["result"]
            # Only an explicit rejection proves work was not accepted. The bridge may
            # still be exiting after its provider terminal; never replay an unknown run.
            if op == "submit" and result.get("error") == "worker-busy" and time.monotonic() < deadline:
                time.sleep(.1)
                continue
            assert "error" not in result, f"host rejected {op}: {result.get('error')}"
            return result

    def terminal(self, run_id):
        return self.until(lambda f: f.get("event", {}).get("runId") == run_id and
                          f["event"]["kind"] in ("completed", "failed", "stopped", "unconfirmed"))["event"]

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("host", "node", "worker", "evidence"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--live", action="store_true", help="explicitly perform authorized real model fixture turns")
    args = parser.parse_args()
    if not args.live:
        parser.error("use --live for the already-authorized bounded official-client model check")
    for name in ("host", "node", "worker"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    if args.evidence.exists():
        parser.error("evidence already exists; use a fresh path")
    profile = Path(tempfile.mkdtemp(prefix="yorozu-alpha-qa-"))
    result = {"format": 1, "profile": str(profile), "checks": {}, "nativeComputerUse": "blocked; no existing TCC grants proven"}
    frames = []
    host = None
    try:
        host = Host(args, profile)
        snapshot = host.request("snapshot")
        workspace = Path(snapshot["workspace"])
        assert workspace.resolve() == (profile / "workspace").resolve()
        result["checks"]["isolatedSnapshot"] = True
        for language, prompt, marker in [
            ("english", "Create only english.txt containing exactly ALPHA_EN_OK followed by a newline. Compute its SHA-256 and report it. Do not access other files or accounts.", "ALPHA_EN_OK\n"),
            ("japanese", "この作業フォルダーだけで japanese.txt を作成し、内容を正確に「こんにちは、よろず」に改行を一つ付けてください。SHA-256を計算して結果を報告してください。他のファイルやアカウントにはアクセスしないでください。", "こんにちは、よろず\n"),
        ]:
            run_id = str(uuid.uuid4())
            accepted = host.request("submit", runId=run_id, text=prompt)
            assert accepted.get("accepted") is True
            done = host.terminal(run_id)
            assert done["kind"] == "completed", f"{language} ended {done['kind']}"
            actual = (workspace / (language + ".txt")).read_bytes()
            assert actual == marker.encode(), f"{language} fixture content incorrect"
            digest = hashlib.sha256(actual).hexdigest()
            assert digest in done.get("text", ""), f"{language} final result omitted independently verified SHA-256"
            replay = host.request("submit", runId=run_id, text=prompt)
            assert replay.get("replayed") is True
            result["checks"][language] = {"runId": run_id, "sha256": digest, "terminal": "completed", "idempotentReplay": True}
        stop_run = str(uuid.uuid4())
        host.request("submit", runId=stop_run, text="Do not access files, accounts or tools. Think carefully about explaining prime numbers for a long answer. Await cancellation if requested.")
        host.until(lambda f: f.get("event", {}).get("runId") == stop_run and f["event"]["kind"] == "running", 15)
        stopped = host.request("stop", runId=stop_run)
        assert stopped.get("requested") is True, "Stop request was not durably accepted"
        terminal = host.terminal(stop_run)
        assert terminal["kind"] == "stopped", f"Stop cessation unproven: {terminal['kind']}"
        assert terminal.get("data"), "Stop missing cessation evidence"
        result["checks"]["stop"] = terminal
        before = host.request("snapshot")
        frames.extend(host.frames)
        host.close()
        host = Host(args, profile)
        after = host.request("snapshot")
        assert after["events"] == before["events"], "reconnect changed retained terminal events"
        assert after["activeRunId"] is None
        result["checks"]["reconnect"] = {"retainedEvents": len(after["events"]), "activeRunId": None}
        result["passed"] = True
    except Exception as error:
        result["passed"] = False
        result["blocker"] = f"{type(error).__name__}: {error}"
    finally:
        if host:
            frames.extend(host.frames)
            host.close()
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps({**result, "frames": frames}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "frames"}, ensure_ascii=False))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
