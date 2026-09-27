import { expect, test } from "vitest";
import { UpdateGate } from "./update-gate.js";

test("idle wins before the 24 hour drain deadline", () => {
  const gate = new UpdateGate();
  gate.queue("update", "1.0", 1_000);
  expect(gate.poll(2, 1_000).phase).toBe("waiting");
  expect(gate.poll(3, 86_400_000).phase).toBe("waiting");
  expect(gate.poll(0, 86_400_000).deadline).toBe(86_410_000);
  gate.activity();
  expect(gate.poll(0, 86_400_500).deadline).toBe(86_410_500);
  for (let second = 1; second < 10; second++) gate.poll(0, 86_400_500 + second * 1_000);
  expect(gate.poll(0, 86_410_500).phase).toBe("installing");
});

test("busy update drains after 24 hours, installs at safe point or hard deadline", () => {
  const gate = new UpdateGate();
  gate.queue("update", "1.0", 1_000);
  expect(gate.poll(1, 86_400_999).phase).toBe("waiting");
  expect(gate.poll(1, 86_401_000)).toMatchObject({ phase: "draining", deadline: 86_701_000 });
  expect(gate.poll(0, 86_401_001).phase).toBe("installing");
  const stuck = new UpdateGate();
  stuck.queue("update", "1.0", 1_000);
  stuck.poll(1, 86_401_000);
  expect(stuck.poll(null, 86_402_000).phase).toBe("unknown");
  expect(stuck.draining).toBe(true);
  expect(stuck.poll(1, 86_701_000).phase).toBe("installing");
});

test("manual install overrides postponement; postponement cancels a drain", () => {
  const gate = new UpdateGate();
  gate.queue("update", "1.0", 1_000);
  gate.postpone(2_000);
  expect(gate.poll(1, 86_401_000).phase).toBe("draining");
  gate.postpone(86_402_000);
  expect(gate.poll(1, 86_403_000).phase).toBe("postponed");
  gate.installNow();
  expect(gate.poll(1, 86_403_001).phase).toBe("draining");
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
