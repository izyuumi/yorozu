/**
 * Minimal 5-field cron matcher: `minute hour day-of-month month day-of-week`.
 * Supports numbers, wildcards, steps (a wildcard or start value followed by `/n`),
 * lists (`a,b`) and ranges (`a-b`, optionally stepped). No names, no `@daily`, no
 * seconds: the scheduler only ever asks "does this expression match this minute?".
 * See docs/spec-v1.html section 4.
 */

/** Inclusive bounds per field, in expression order. Day-of-week takes 7 as a second Sunday. */
const BOUNDS: [number, number][] = [
  [0, 59],
  [0, 23],
  [1, 31],
  [1, 12],
  [0, 7],
];

export interface Cron {
  minute: Set<number>;
  hour: Set<number>;
  dayOfMonth: Set<number>;
  month: Set<number>;
  dayOfWeek: Set<number>;
  /** Both day fields restricted means "either matches", as in Vixie cron. */
  dayIsOr: boolean;
}

function parseField(spec: string, min: number, max: number): Set<number> {
  const values = new Set<number>();
  for (const part of spec.split(",")) {
    const [range, stepText, ...rest] = part.split("/");
    if (range === undefined || range === "" || rest.length) throw new Error(`bad cron field: ${spec}`);
    const step = stepText === undefined ? 1 : Number(stepText);
    if (!Number.isInteger(step) || step < 1) throw new Error(`bad cron step: ${part}`);

    let lo: number;
    let hi: number;
    if (range === "*") {
      [lo, hi] = [min, max];
    } else if (range.includes("-")) {
      const [from, to, ...extra] = range.split("-");
      if (extra.length) throw new Error(`bad cron range: ${part}`);
      [lo, hi] = [Number(from), Number(to)];
    } else {
      // `5/15` is cron for "from 5 to the end of the field, every 15".
      lo = Number(range);
      hi = stepText === undefined ? lo : max;
    }

    if (!Number.isInteger(lo) || !Number.isInteger(hi) || lo < min || hi > max || lo > hi) {
      throw new Error(`bad cron field: ${part}`);
    }
    for (let value = lo; value <= hi; value += step) values.add(value);
  }
  return values;
}

/** Throws on anything that is not a 5-field expression this matcher understands. */
export function parseCron(expression: string): Cron {
  const fields = expression.trim().split(/\s+/);
  if (fields.length !== 5) throw new Error(`cron needs 5 fields, got ${fields.length}: ${expression}`);
  const [minute, hour, dayOfMonth, month, dayOfWeek] = fields.map((field, i) =>
    parseField(field, BOUNDS[i]![0], BOUNDS[i]![1]),
  ) as Set<number>[];
  // Sunday is both 0 and 7 on the wire; the Date API only ever says 0.
  if (dayOfWeek!.has(7)) dayOfWeek!.add(0);
  return {
    minute: minute!,
    hour: hour!,
    dayOfMonth: dayOfMonth!,
    month: month!,
    dayOfWeek: dayOfWeek!,
    dayIsOr: fields[2] !== "*" && fields[4] !== "*",
  };
}

/** True when `date` (local time, to the minute) falls on the expression. */
export function matchesCron(expression: string | Cron, date: Date): boolean {
  const cron = typeof expression === "string" ? parseCron(expression) : expression;
  const dayOfMonth = cron.dayOfMonth.has(date.getDate());
  const dayOfWeek = cron.dayOfWeek.has(date.getDay());
  return (
    cron.minute.has(date.getMinutes()) &&
    cron.hour.has(date.getHours()) &&
    cron.month.has(date.getMonth() + 1) &&
    (cron.dayIsOr ? dayOfMonth || dayOfWeek : dayOfMonth && dayOfWeek)
  );
}
