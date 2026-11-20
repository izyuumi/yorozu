# 0030. Help MCP server and its content bundle

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Agents helping the owner set up Yorozu can ask a help MCP server (`apps/mcp`). It must answer only from public repository content and run both on Node and inside the website's worker.

## Decision

- Transport: stateless Streamable HTTP on web-standard `Request` and `Response`, so the same code serves Node (`src/http.ts`) and the website's Cloudflare Worker. Each POST gets a fresh server; nothing is kept between requests. With JSON responses the body is complete once `handleRequest` returns, so the transport closes then.
- The website serves it at `/mcp` with a health check at `/healthz`, answering from the bundled content alone. The rate limit counts per visitor IP within the isolate.
- `/llm.txt` serves the same bytes as `public/llms.txt`, for agents that ask for the singular name.
- Node HTTP server:
  - `trustProxy` is the number of reverse proxies whose `X-Forwarded-For` entries are trusted; 0 uses the socket address. With N trusted proxies the client IP is the Nth entry from the right; the proxy appends the real client last, so a spoofed left-hand entry does not change the key.
  - A target the URL parser rejects (`//%`; Node's HTTP parser accepts it) or a method `Request` refuses (TRACE) is caught.
  - The body is read before the status line goes out, so a failed read can still answer 500.
- stdio transport: `npx <path to apps/mcp>` or `node src/stdio.ts`. Logs go to stderr; stdout carries MCP.
- Search scoring: heading hits weigh 5, body hits 1 (capped at 5 per term); matching every term doubles the score.
- Content bundle:
  - `scripts/generate.ts` builds `src/content.json` from the repository: README and docs, the app's settings keys, the Info.plist usage strings and entitlements, the troubleshooting tables and `CHANGELOG.md`. Paths resolve from the script file, so it runs from anywhere. The server reads only this file at runtime.
  - `--check` fails when the committed bundle differs from what the sources produce, except for release notes alone: a stable release PR changes only `CHANGELOG.md` and must stay green; the next regeneration picks them up.
  - An optional setting (`var x: Kind?`) has no default: `null`, unset until the owner picks one. The voice package's sources are scanned too, since it declares the types some settings store.
  - Patterns that must never reach the public bundle: home-directory paths, email addresses and credential shapes.
- Tests: any outbound fetch fails the test. The stdio test runs under Node's permission model, reading only files under the repository (no network, writes or child processes). Node 24 has no network permission (`--allow-net` came in Node 25), so there the sandbox does not block connections; the control test uses a listening server so a refused connection cannot pass for a denied one. HTTP tests use their own client IP so they don't use up another test's rate-limit window.

## Consequences

- The help server cannot leak anything that isn't already public in the repository.

## Where in the code

- `apps/mcp/src/fetch.ts` — `createHandler`
- `apps/mcp/src/http.ts` — `HttpOptions.trustProxy`, `clientIp`, `createHttpServer`
- `apps/mcp/src/stdio.ts`
- `apps/mcp/src/help.ts` — `score`
- `apps/mcp/src/content.ts` — `bundle`, `AppSetting.default`
- `apps/mcp/scripts/generate.ts`, `apps/mcp/scripts/privacy.ts`
- `apps/mcp/test/http.test.ts`, `apps/mcp/test/stdio.test.ts`
- `apps/web/worker.mjs` — `helpMcp`
- `apps/web/src/pages/llm.txt.js` — `GET`
- `apps/web/tests/mcp.test.mjs`
