/**
 * Provider adapters are thin: `stream` and `auth` only. The loop owns messages,
 * tool dispatch and history. See docs/spec-v1.html section 2.
 */

import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";
import { env } from "node:process";

export interface ToolCall {
  id: string;
  name: string;
  /** Raw JSON string as the model emitted it. */
  arguments: string;
}

/** An attached image, ready to hand to a provider that can see one. Standard base64. */
export interface MessageImage {
  mime: string;
  data: string;
}

export interface Message {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  /**
   * Images the user attached. Only ever set when the provider declares `vision`, because a
   * provider that cannot see one is given the file's name in `content` instead — see
   * `threadHistory` in threads.ts, which is where that choice is made.
   */
  images?: MessageImage[];
}

export interface ToolDef {
  name: string;
  description: string;
  /** JSON Schema for the tool arguments. */
  parameters: unknown;
}

export type ProviderEvent =
  | { type: "text"; text: string }
  | { type: "tool_call"; call: ToolCall }
  | { type: "done"; reason?: string };

export interface Provider {
  stream(messages: Message[], tools: ToolDef[]): AsyncIterable<ProviderEvent>;
  auth(): Promise<{ ok: boolean; reason?: string }>;
  /**
   * Whether `stream` can be handed `Message.images`. False or absent for the two CLI adapters:
   * they flatten the transcript into one prompt string (see `renderTranscript`), so there is
   * nowhere for the bytes to go, whatever the model behind the CLI could have done with them.
   */
  vision?: boolean;
  /**
   * Provider-native web search, as already-read results rather than raw HTML. Optional:
   * a provider without one is why `web_search` keeps a browser fallback. See tools/search.ts.
   */
  search?(query: string): Promise<string>;
}

export interface OpenAICompatConfig {
  /** With or without a trailing `/v1`; both are accepted. */
  baseUrl: string;
  apiKey?: string;
  model: string;
  /**
   * Whether the configured model can be sent images. Defaults to true: the content-parts shape
   * below is plain OpenAI chat-completions, which every endpoint worth calling accepts, and a
   * text-only model behind one is the rarer case to have to turn off.
   */
  vision?: boolean;
  /** Injectable for tests. */
  fetch?: typeof fetch;
}

/** Yields the payload of each `data:` line of an SSE response. */
async function* sseData(res: Response): AsyncGenerator<string> {
  const reader = res.body!.pipeThrough(new TextDecoderStream()).getReader();
  let buf = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += value;
    for (let i; (i = buf.indexOf("\n")) >= 0; buf = buf.slice(i + 1)) {
      const line = buf.slice(0, i).trim();
      if (line.startsWith("data:")) yield line.slice(5).trim();
    }
  }
  const last = buf.trim();
  if (last.startsWith("data:")) yield last.slice(5).trim();
}

/**
 * Shared by the two subscription-CLI adapters below this file: they talk to a local
 * binary rather than an HTTP endpoint, so they need to find it and to flatten our
 * message list into the single prompt those CLIs take.
 */

/** Path of the first executable of that name on PATH, or undefined. Never runs it. */
export function onPath(name: string): string | undefined {
  for (const dir of (env.PATH ?? "").split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, name);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Not here; keep walking PATH.
    }
  }
  return undefined;
}

/**
 * Runs a CLI and resolves both its streams. Used by the auth probes only, and they need
 * both: `codex login status` reports on stderr and still exits 0.
 */
export function runCli(
  file: string,
  args: string[],
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(file, args, { timeout: 10_000 }, (error, stdout, stderr) =>
      error ? reject(error) : resolve({ stdout, stderr }),
    );
  });
}

/** The system messages, which the CLIs take separately from the conversation. */
export const systemOf = (messages: Message[]): string =>
  messages
    .filter((m) => m.role === "system")
    .map((m) => m.content)
    .join("\n\n");

/**
 * The conversation as one prompt. The CLIs own no history here — the loop replays the
 * whole transcript each turn, exactly as it does for the HTTP adapter.
 */
export function renderTranscript(messages: Message[]): string {
  const lines: string[] = [];
  for (const message of messages) {
    if (message.role === "system") continue;
    if (message.role === "tool") {
      lines.push(`Tool result (${message.tool_call_id}): ${message.content}`);
      continue;
    }
    const calls = (message.tool_calls ?? []).map(
      (call) => `\n[called ${call.name} with ${call.arguments} as ${call.id}]`,
    );
    const body = `${message.content}${calls.join("")}`;
    if (body) lines.push(`${message.role === "user" ? "User" : "Assistant"}: ${body}`);
  }
  return lines.join("\n\n");
}

export function openaiCompat(config: OpenAICompatConfig): Provider & {
  listModels(): Promise<string[]>;
} {
  const base =
    config.baseUrl.replace(/\/+$/, "").replace(/\/v1$/, "") + "/v1";
  const doFetch = config.fetch ?? globalThis.fetch;
  const headers = {
    "content-type": "application/json",
    ...(config.apiKey ? { authorization: `Bearer ${config.apiKey}` } : {}),
  };

  async function request(path: string, init?: RequestInit): Promise<Response> {
    const res = await doFetch(`${base}${path}`, { ...init, headers });
    if (!res.ok) {
      throw new Error(
        `${path} ${res.status}: ${await res.text().catch(() => "")}`,
      );
    }
    return res;
  }

  async function listModels(): Promise<string[]> {
    const body = (await (await request("/models")).json()) as {
      data?: { id: string }[];
    };
    return (body.data ?? []).map((m) => m.id);
  }

  /**
   * One message as the endpoint wants it. `content` is a plain string unless images came with
   * it, in which case it becomes the parts array — text first, then each image as a data URL,
   * which is how an inline image is sent when there is no URL to point at.
   */
  function wireMessage(m: Message): Record<string, unknown> {
    const { images, tool_calls, ...rest } = m;
    return {
      ...rest,
      ...(images?.length
        ? {
            content: [
              ...(m.content ? [{ type: "text", text: m.content }] : []),
              ...images.map((image) => ({
                type: "image_url",
                image_url: { url: `data:${image.mime};base64,${image.data}` },
              })),
            ],
          }
        : {}),
      ...(tool_calls
        ? {
            tool_calls: tool_calls.map((c) => ({
              id: c.id,
              type: "function",
              function: { name: c.name, arguments: c.arguments },
            })),
          }
        : {}),
    };
  }

  return {
    listModels,
    vision: config.vision ?? true,

    async auth() {
      try {
        await listModels();
        return { ok: true };
      } catch (e) {
        return { ok: false, reason: e instanceof Error ? e.message : String(e) };
      }
    },

    async *stream(messages, tools) {
      const res = await request("/chat/completions", {
        method: "POST",
        body: JSON.stringify({
          model: config.model,
          stream: true,
          messages: messages.map(wireMessage),
          ...(tools.length
            ? { tools: tools.map((t) => ({ type: "function", function: t })) }
            : {}),
        }),
      });

      const calls: ToolCall[] = [];
      let reason: string | undefined;
      for await (const data of sseData(res)) {
        if (data === "[DONE]") break;
        const choice = (
          JSON.parse(data) as {
            choices?: {
              delta?: {
                content?: string;
                tool_calls?: {
                  index?: number;
                  id?: string;
                  function?: { name?: string; arguments?: string };
                }[];
              };
              finish_reason?: string;
            }[];
          }
        ).choices?.[0];
        if (!choice) continue;
        if (choice.delta?.content) {
          yield { type: "text", text: choice.delta.content };
        }
        for (const tc of choice.delta?.tool_calls ?? []) {
          const call = (calls[tc.index ?? 0] ??= {
            id: "",
            name: "",
            arguments: "",
          });
          if (tc.id) call.id = tc.id;
          // Name and arguments both arrive split across chunks.
          call.name += tc.function?.name ?? "";
          call.arguments += tc.function?.arguments ?? "";
        }
        if (choice.finish_reason) reason = choice.finish_reason;
      }
      for (const call of calls) if (call) yield { type: "tool_call", call };
      yield { type: "done", reason };
    },
  };
}
