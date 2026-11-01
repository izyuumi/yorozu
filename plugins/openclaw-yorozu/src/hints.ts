import { promises as dns } from "node:dns";
import { isIP } from "node:net";
import { networkInterfaces, type NetworkInterfaceInfo } from "node:os";
import { bindAddresses, directAddress, type DirectListener } from "./direct.js";
import type { DirectHints } from "./envelope.js";
import type { Log } from "./hub.js";

type Interfaces = NodeJS.Dict<NetworkInterfaceInfo[]>;
const loopback = (address: string) => address.startsWith("127.") || (isIP(address) === 6 && /^0*:?0*:?0*:?0*:?0*:?0*:?0*:?1$/.test(address));
export const tailscaleAddress = (address: string): boolean => {
  if (isIP(address) === 4) {
    const [a, b = 0] = address.split(".").map(Number);
    return a === 100 && b >= 64 && b <= 127;
  }
  return /^fd7a:115c:a1e0:/i.test(address);
};

function prefix(info: NetworkInterfaceInfo): number | undefined {
  const bits = isIP(info.address) === 4 ? 32 : 128;
  const cidr = info.cidr?.split("/")[1];
  if (cidr !== undefined && /^\d+$/.test(cidr) && Number(cidr) <= bits) return Number(cidr);
  let mask: string;
  if (isIP(info.netmask) === 4) mask = info.netmask.split(".").map((n) => Number(n).toString(2).padStart(8, "0")).join("");
  else if (isIP(info.netmask) === 6) {
    const [head = "", tail] = info.netmask.split("::");
    const front = head ? head.split(":") : [];
    const back = tail ? tail.split(":") : [];
    mask = [...front, ...Array<string>(8 - front.length - back.length).fill("0"), ...back]
      .map((n) => parseInt(n, 16).toString(2).padStart(16, "0")).join("");
  } else return undefined;
  return /^1*0*$/.test(mask) ? mask.indexOf("0") === -1 ? bits : mask.indexOf("0") : undefined;
}

/** Introduced by feature flag `direct` (#532); only addresses successfully bound by the listener are advertised. */
export function directHints(interfaces: Interfaces, port: number, magicDNS?: string): DirectHints {
  const lan = new Map<string, { address: string; prefix: number }>();
  const tailscale = new Set<string>();
  for (const info of Object.values(interfaces).flatMap((list) => list ?? [])) {
    const address = info.address;
    if (!directAddress(address) || loopback(address)) continue;
    if (tailscaleAddress(address)) tailscale.add(address);
    else {
      const length = prefix(info);
      if (length !== undefined && length < (lan.get(address)?.prefix ?? Infinity)) lan.set(address, { address, prefix: length });
    }
  }
  return { port, lan: [...lan.values()].sort((a, b) => a.address.localeCompare(b.address) || a.prefix - b.prefix),
    tailscale: [...tailscale].sort().map((address) => ({ address })), ...(magicDNS && { magicDNS }) };
}

export async function resolveMagicDNS(address: string, reverse = dns.reverse, timeoutMs = 2_000): Promise<string | undefined> {
  let timer: NodeJS.Timeout | undefined;
  try {
    const names = await Promise.race([reverse(address), new Promise<string[]>((resolve) => {
      timer = setTimeout(() => resolve([]), timeoutMs);
      timer.unref();
    })]);
    return names.map((name) => name.replace(/\.$/, "")).find((name) =>
      name.length <= 253 && /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+ts\.net$/i.test(name));
  } catch { return undefined; }
  finally { clearTimeout(timer); }
}

/** Serial polling keeps rebinding and DNS results in interface order; stop waits for an in-flight refresh. */
export async function watchDirect(opts: {
  listener: DirectListener; port: number; source?: () => Interfaces; intervalMs?: number;
  reverse?: typeof dns.reverse; changed: (hints: DirectHints | undefined) => void | Promise<void>; log?: Log;
}): Promise<() => Promise<void>> {
  let stopped = false;
  let previous = "";
  let tail: string | undefined;
  let magicDNS: string | undefined;
  const refresh = async () => {
    if (stopped) return;
    const interfaces = (opts.source ?? networkInterfaces)();
    const old = opts.listener.bound;
    await opts.listener.update(bindAddresses(interfaces));
    const bound = opts.listener.bound;
    const changes = [...bound.filter((a) => !old.includes(a)).map((a) => `+${a}`), ...old.filter((a) => !bound.includes(a)).map((a) => `-${a}`)];
    if (changes.length) opts.log?.info(`yorozu: direct addresses changed: ${changes.join(" ")}`);
    const filtered = Object.fromEntries(Object.entries(interfaces).map(([name, list]) => [name, list?.filter((i) => bound.includes(i.address))]));
    const hints = directHints(filtered, opts.port);
    const address = hints.tailscale.find((i) => isIP(i.address) === 4)?.address;
    if (address !== tail) {
      tail = address;
      magicDNS = address ? await resolveMagicDNS(address, opts.reverse) : undefined;
    }
    if (magicDNS) hints.magicDNS = magicDNS;
    const current = JSON.stringify([opts.listener.listening, hints]);
    if (!stopped && current !== previous) {
      previous = current;
      await opts.changed(opts.listener.listening ? hints : undefined);
    }
  };
  await refresh();
  let running: Promise<void> | undefined;
  const timer = setInterval(() => {
    if (running) return;
    running = refresh().catch((error: unknown) => opts.log?.warn(`yorozu: direct refresh failed: ${String(error)}`)).finally(() => { running = undefined; });
  }, opts.intervalMs ?? 5_000);
  timer.unref();
  return async () => { stopped = true; clearInterval(timer); await running; };
}
