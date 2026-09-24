import { expect, test } from "vitest";
import { UpdateGate } from "./update-gate.js";

test("new work, approval waits and retries keep the update queued without a deadline", () => {
  const gate = new UpdateGate();
  gate.queue("update", "1.0");
  expect(gate.poll(2, 1_000).phase).toBe("waiting");
  expect(gate.poll(3, 86_400_000).phase).toBe("waiting");
  expect(gate.poll(0, 86_401_000).deadline).toBe(86_411_000);
  gate.activity();
  expect(gate.poll(0, 86_402_000).deadline).toBe(86_412_000);
  for (let second = 3; second < 12; second++) expect(gate.poll(0, 86_400_000 + second * 1_000).phase).toBe("countdown");
  expect(gate.poll(0, 86_412_000).phase).toBe("installing");
});

test("unknown status and a missing updater heartbeat require a fresh countdown", () => {
  const gate = new UpdateGate();
  gate.queue("update", "1.0");
  gate.poll(0, 1_000);
  expect(gate.poll(null, 2_000).phase).toBe("unknown");
  expect(gate.poll(0, 3_000).deadline).toBe(13_000);
  expect(gate.poll(0, 30_000).deadline).toBe(40_000);
});

test("postponement survives requeue and requires ten idle seconds after expiry", () => {
  const gate = new UpdateGate();
  gate.queue("update", "1.0");
  const until = gate.postpone(1_000);
  gate.cancel();
  gate.queue("next", "1.1");
  expect(gate.poll(0, until - 1).phase).toBe("postponed");
  expect(gate.poll(0, until).deadline).toBe(until + 10_000);
  const restored = new UpdateGate(until);
  restored.queue("update", "1.0");
  expect(restored.poll(0, 2_000).phase).toBe("postponed");
});
