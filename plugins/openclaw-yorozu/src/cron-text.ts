/** The fields of an OpenClaw cron schedule that the text reads; this file imports nothing from OpenClaw. */
export type ScheduleLike = { kind: string; everyMs?: number; expr?: string; tz?: string };

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

export function describeSchedule(schedule: ScheduleLike): string {
  switch (schedule.kind) {
    case "at":
      return "Once";
    case "every": {
      const ms = schedule.everyMs;
      return typeof ms === "number" && ms > 0 ? `Every ${duration(ms)}` : "Custom";
    }
    case "cron": {
      const tz = schedule.tz ? ` (${schedule.tz})` : "";
      return `${describeCron((schedule.expr ?? "").trim())}${tz}`;
    }
    case "on-exit":
      return "When a command exits";
    case "stream":
      return "On command output";
    default:
      return "Custom";
  }
}

function duration(ms: number): string {
  const units: [number, string][] = [[86_400_000, "day"], [3_600_000, "hour"], [60_000, "minute"], [1_000, "second"]];
  for (const [size, unit] of units) {
    if (ms % size === 0) {
      const n = ms / size;
      return n === 1 ? unit : `${n} ${unit}s`;
    }
  }
  return `${ms} ms`;
}

/** The ranges are those of `CronSchedule.cron` in the app, which shows this text when it declines a schedule. */
function describeCron(expr: string): string {
  const fields = expr.split(/\s+/);
  if (fields.length !== 5) return `Cron ${expr}`;
  const [min, hour, dom, month, dow] = fields as [string, string, string, string, string];
  const num = (s: string) => /^\d{1,2}$/.test(s);
  const minute = num(min) && Number(min) < 60;
  const at = minute && num(hour) && Number(hour) < 24 ? `at ${hour.padStart(2, "0")}:${min.padStart(2, "0")}` : null;
  const step = /^\*\/(\d+)$/.exec(min);
  if (step && Number(step[1]) > 0 && hour === "*" && dom === "*" && month === "*" && dow === "*") return `Every ${step[1]} minutes`;
  if (minute && hour === "*" && dom === "*" && month === "*" && dow === "*") return `Hourly at :${min.padStart(2, "0")}`;
  if (at && month === "*") {
    if (dom === "*" && dow === "*") return `Daily ${at}`;
    if (dom === "*" && (dow === "1-5" || dow === "MON-FRI")) return `Weekdays ${at}`;
    if (dom === "*" && /^[0-7]$/.test(dow)) return `${DAYS[Number(dow) % 7]}s ${at}`;
    if (num(dom) && Number(dom) >= 1 && Number(dom) <= 31 && dow === "*") return `Monthly on day ${Number(dom)} ${at}`;
  }
  return `Cron ${expr}`;
}
