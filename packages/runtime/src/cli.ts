import { createInterface } from "node:readline/promises";
import { env, exit, stdin, stdout } from "node:process";
import { defaultTools, runAgent } from "./index.js";
import { openaiCompat, type Message } from "./provider.js";

const SYSTEM =
  "You are Yorozu, a personal assistant. Use the echo tool when asked to echo.";

const provider = openaiCompat({
  baseUrl: env.YOROZU_BASE_URL ?? "https://api.openai.com/v1",
  apiKey: env.YOROZU_API_KEY,
  model: env.YOROZU_MODEL ?? "gpt-4o-mini",
});

const auth = await provider.auth();
if (!auth.ok) {
  console.error(`auth failed: ${auth.reason}`);
  exit(1);
}

// Iterating the interface (rather than question()) ends cleanly at EOF.
const rl = createInterface({ input: stdin, output: stdout, prompt: "> " });
const messages: Message[] = [];
/** Prompting after stdin hit EOF would throw ERR_USE_AFTER_CLOSE. */
let closed = false;
rl.on("close", () => {
  closed = true;
});
const prompt = () => {
  if (!closed) rl.prompt();
};

prompt();
for await (const raw of rl) {
  const line = raw.trim();
  if (line === "/exit") break;
  if (!line) {
    prompt();
    continue;
  }
  if (line === "/models") {
    console.log((await provider.listModels()).join("\n"));
    prompt();
    continue;
  }
  messages.push({ role: "user", content: line });

  for await (const event of runAgent({
    provider,
    system: SYSTEM,
    messages,
    tools: defaultTools,
  })) {
    if (event.type === "text") stdout.write(event.text);
    else if (event.type === "tool_call")
      stdout.write(`\n[tool_call] ${event.call.name} ${event.call.arguments}\n`);
    else if (event.type === "tool_result")
      stdout.write(`[tool_result] ${event.name} -> ${event.result}\n`);
    // ponytail: only the final assistant text is kept across turns; carry the
    // full tool history too once threads land.
    else messages.push({ role: "assistant", content: event.text });
  }
  stdout.write("\n");
  prompt();
}

rl.close();
