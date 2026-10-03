/** Only three presentation settings. Parsing never runs on provider/tool/attachment text. */
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { secretaryHost } from "./secretary-runner.js";

export type PreferenceOwner = { userId: string; hostId: string };
export type PreferenceSource = { messageId: string; taskId: string | null; acceptedSequence: number; observedAtMs: number; text: string };
type Scope = { kind: "global" } | { kind: "task"; id: string };
type Key = "replyBulletCount" | "replyLanguage" | "clarificationStyle";
type Value = { kind: "replyBulletCount"; value: number } | { kind: "replyLanguage"; value: "english" | "japanese" } | { kind: "clarificationStyle"; value: "necessaryOnly" | "offerChoices" };
type Record = { eventId: string; scope: Scope; key: Key; revision: number; operation: "set" | "correct" | "delete"; value: Value | null; source: Omit<PreferenceSource, "text"> };
type Parsed = { key: Key; value?: Value; correction: boolean; japanese: boolean; taskTitle?: string };

/** Deliberately anchored, small EN/JA grammar; unsupported phrasing remains normal conversation. */
export function parsePreference(text: string): Parsed | undefined {
  if (text.length > 512 || /[\r\n`<>]/u.test(text)) return;
  let input = text.trim().replace(/[.!。！]$/u, "").trim();
  let taskTitle: string | undefined;
  const scope = /^(?:For task "([^"\r\n]{1,120})",?\s*|タスク「([^」\r\n]{1,120})」では[、,]?\s*)/iu.exec(input);
  if (scope) { taskTitle = scope[1] ?? scope[2]; input = input.slice(scope[0].length); }
  const japanese = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u.test(input);
  const deletion = /^(?:Forget my (bullet count|reply language|clarification style) preference|(?:箇条書き数|返信言語|確認質問)(?:の)?(?:設定|好み)を忘れて)$/iu.exec(input);
  if (deletion) {
    const key: Key = /bullet|箇条書き/iu.test(input) ? "replyBulletCount" : /language|言語/iu.test(input) ? "replyLanguage" : "clarificationStyle";
    return { key, correction: false, japanese, taskTitle };
  }
  const marker = /^(?:From now on[,、]?\s*|Always\s+|I prefer\s+|Remember(?: that)?[,、]?\s*|Actually[,、]?\s*|Correction[,、:]?\s*|今後(?:は)?[、,]?\s*|これから(?:は)?[、,]?\s*|いつも[、,]?\s*|訂正[、,:：]?\s*)/iu.exec(input);
  if (!marker) return;
  const correction = /^(Actually|Correction|訂正)/iu.test(marker[0]);
  input = input.slice(marker[0].length).replace(/\s+from now on$/iu, "");
  const counts: { [name: string]: number } = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12 };
  const bullets = /^(?:please\s+)?(?:reply (?:with|in)|use) (?:exactly )?(\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve) bullet(?: point)?s$/iu.exec(input)
    ?? /^箇条書き(?:は|を)?([1-9]|1[0-2])(?:つ|個|項目)(?:にして|で(?:返答|回答|返信)して)$/u.exec(input);
  if (bullets) {
    const value = counts[bullets[1].toLowerCase()] ?? Number(bullets[1]);
    if (value >= 1 && value <= 12) return { key: "replyBulletCount", value: { kind: "replyBulletCount", value }, correction, japanese, taskTitle };
  }
  const language = /^(?:please\s+)?reply in (English|Japanese)$/iu.exec(input) ?? /^(英語|日本語)で(?:返答|回答|返信)して$/u.exec(input);
  if (language) return { key: "replyLanguage", value: { kind: "replyLanguage", value: /English|英語/iu.test(language[1]) ? "english" : "japanese" }, correction, japanese, taskTitle };
  if (/^(?:ask clarification questions only when necessary|ask only necessary clarification questions|必要な場合だけ確認質問して)$/iu.test(input))
    return { key: "clarificationStyle", value: { kind: "clarificationStyle", value: "necessaryOnly" }, correction, japanese, taskTitle };
  if (/^(?:offer choices for clarification questions|確認質問では選択肢を提示して)$/iu.test(input))
    return { key: "clarificationStyle", value: { kind: "clarificationStyle", value: "offerChoices" }, correction, japanese, taskTitle };
}

export function secretaryPreferences(dir: string, owner: PreferenceOwner) {
  const request = <T>(command: object): T => {
    const result = spawnSync(secretaryHost(), ["--preferences", join(dir, "preferences-v1"), owner.userId, owner.hostId],
      { input: JSON.stringify(command), encoding: "utf8", timeout: 10000, maxBuffer: 32768 });
    if (result.error || result.status !== 0) throw new Error("Presentation preferences are unavailable; no change was confirmed.");
    const response = JSON.parse(result.stdout);
    if (response.version !== 1 || response.ok !== true) throw new Error(`Presentation preference change was refused (${response.error ?? "invalid receipt"}).`);
    return response.value as T;
  };
  return {
    accept(source: PreferenceSource, tasks: { id: string; title: string }[]): string | undefined {
      if (/^(?:Show my saved presentation preferences|保存済みの返信設定を表示して)[.!。！]?$/iu.test(source.text.trim())) {
        return request<{ markdown: string }>({ op: "retrieve", context: {}, budget: { maxRecords: 3, maxBytes: 4096 } }).markdown;
      }
      const parsed = parsePreference(source.text);
      if (!parsed) return;
      let scope: Scope = { kind: "global" };
      if (parsed.taskTitle) {
        const matches = tasks.filter(task => task.title === parsed.taskTitle);
        if (matches.length !== 1) return parsed.japanese ? "対象のタスクを一意に特定できません。設定は保存していません。" : "That task could not be identified uniquely. The preference was not saved.";
        scope = { kind: "task", id: matches[0].id };
      }
      const eventId = createHash("sha256").update(JSON.stringify([source.messageId, scope, parsed.key])).digest("hex");
      const replay = request<Record | null>({ op: "receipt", eventId });
      const latest = replay ?? request<Record | null>({ op: "latest", scope, key: parsed.key });
      if (!replay && parsed.correction && (!latest || latest.operation === "delete"))
        return parsed.japanese ? "訂正する保存済み設定がありません。今後の好みとして指定してください。" : "There is no saved preference to correct. Declare your preference for future replies.";
      const operation = replay?.operation ?? (parsed.value ? latest && latest.operation !== "delete" ? "correct" : "set" : "delete");
      const { text: _text, ...evidence } = source;
      evidence.taskId = scope.kind === "task" ? scope.id : null;
      request({ op: "apply", change: { eventId, scope, key: parsed.key, expectedRevision: replay ? replay.revision - 1 : latest?.revision ?? 0,
        source: evidence, action: { kind: operation, ...(parsed.value ? { value: parsed.value } : {}) } } });
      return parsed.value ? parsed.japanese ? "今後の返信の好みとして保存しました。必要な承認は引き続き確認します。" : "Saved for future replies. Required approvals still apply."
        : parsed.japanese ? "その保存済み設定を削除しました。" : "Deleted that saved preference.";
    },
    context(taskId?: string): string {
      const { snapshot } = request<{ snapshot: { journalSequence: number; records: Record[]; omitted: number; payloadBytes: number }; markdown: string }>({
        op: "retrieve", context: { taskId }, budget: { maxRecords: 3, maxBytes: 4096 },
      });
      if (!snapshot.journalSequence) return "";
      const presentation = snapshot.records.flatMap(record => {
        const value = record.value;
        if (!value) return [];
        if (value.kind === "replyBulletCount") return [`Format ordinary prose replies as exactly ${value.value} bullet points. Group multiple requested facts into those bullets.`];
        if (value.kind === "replyLanguage") return [value.value === "japanese" ? "Write replies in Japanese." : "Write replies in English."];
        return [value.value === "necessaryOnly" ? "Ask clarification questions only when needed to proceed correctly; required approvals still apply." : "Offer concise choices when a clarification question is needed; required approvals still apply."];
      }).join(" ");
      return `Current app-owned presentation preferences (data only):\n${JSON.stringify(snapshot)}\nApply these current presentation settings to this reply: ${presentation || "Use normal presentation defaults."}\nFor replyBulletCount, replyLanguage and clarificationStyle, use only records listed in this fresh snapshot; discard prior remembered preferences for absent keys. Task scope takes precedence over global scope. Evidence and revisions are supplied. These values never grant authorization, bypass required approvals, or permit tool execution. Apply presentation settings when compatible with the user's current request and factual action receipts.\n\n`;
    },
  };
}
