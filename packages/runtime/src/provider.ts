/**
 * Provider adapters are thin: `stream` and `auth` only. The loop owns messages,
 * tool dispatch and history. See docs/spec-v1.html section 2.
 */

export interface ToolCall {
  id: string;
  name: string;
  /** Raw JSON string as the model emitted it. */
  arguments: string;
}

export interface Message {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
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
}

export interface OpenAICompatConfig {
  /** With or without a trailing `/v1`; both are accepted. */
  baseUrl: string;
  apiKey?: string;
  model: string;
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

  return {
    listModels,

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
          messages: messages.map((m) =>
            m.tool_calls
              ? {
                  ...m,
                  tool_calls: m.tool_calls.map((c) => ({
                    id: c.id,
                    type: "function",
                    function: { name: c.name, arguments: c.arguments },
                  })),
                }
              : m,
          ),
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
