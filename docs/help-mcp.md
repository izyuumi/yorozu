# Help MCP server

`apps/mcp` (`@yorozu/help-mcp`) is a read-only [Model Context Protocol](https://modelcontextprotocol.io) server that lets an AI agent help someone set up, configure and use Yorozu. It answers only from a content bundle generated from this repository: the README, `docs/`, the plugin README and manifest, `CHANGELOG.md`, and the settings, permissions and error messages in the app's code. It reads nothing from the user's devices, keeps no data, and makes no network calls of its own.

## Tools, resources and prompt

| Name | Kind | What it answers |
|---|---|---|
| `search_docs(query, limit?)` | tool | The best matching doc sections, with their resource URIs |
| `get_setup_guide(platform)` | tool | Setup steps for `ios` (iPhone and iPad) or `macos` |
| `list_settings(platform?)` | tool | Every app setting and every `channels.yorozu` host config key, with defaults |
| `explain_setting(key)` | tool | One setting: what it does, default, options, where to change it, source files |
| `troubleshoot(symptom)` | tool | Cause and fix for an error or state (relay or Gateway offline, pairing, voice model, microphone), plus related docs |
| `get_permissions_needed(platform)` | tool | Permission prompts and entitlements, from `Project.swift` and the Mac entitlements |
| `latest_version()` | tool | The newest version in `CHANGELOG.md` and its notes |
| `changelog(version?, limit?)` | tool | Release notes for one version or the newest few |
| `yorozu://docs/<id>` | resource | Each docs page as Markdown (`readme`, `setup`, `plugin`, …) |
| `setup_yorozu(platform?)` | prompt | "Help me set up Yorozu": a step-by-step setup conversation |

All tools are marked read-only and closed-world.

## Add it to an agent

There are two ways in. The website serves it at `https://yorozu.yumi.to/mcp`. To run it yourself over stdio instead, clone the repository and install once (Node 24 or later):

```sh
pnpm install --filter @yorozu/help-mcp
```

Then use `npx -y <repo>/apps/mcp` as the command, where `<repo>` is the absolute path of the clone. It starts `src/stdio.ts`; there is no build step.

### Claude Code

```sh
claude mcp add --transport http yorozu-help https://yorozu.yumi.to/mcp
# or local:
claude mcp add yorozu-help -- npx -y <repo>/apps/mcp
```

### Claude Desktop

Remote: Settings › Connectors › Add custom connector, URL `https://yorozu.yumi.to/mcp`. Local: add to `claude_desktop_config.json` and restart Claude:

```json
{ "mcpServers": { "yorozu-help": { "command": "npx", "args": ["-y", "<repo>/apps/mcp"] } } }
```

### Codex

```sh
codex mcp add yorozu-help --url https://yorozu.yumi.to/mcp
# or local:
codex mcp add yorozu-help -- npx -y <repo>/apps/mcp
```

Or in `~/.codex/config.toml`:

```toml
[mcp_servers.yorozu-help]
command = "npx"
args = ["-y", "<repo>/apps/mcp"]
# remote instead: url = "https://yorozu.yumi.to/mcp"
```

### Cursor

In `~/.cursor/mcp.json`, or `.cursor/mcp.json` in a project:

```json
{ "mcpServers": { "yorozu-help": { "url": "https://yorozu.yumi.to/mcp" } } }
```

or, local: `{ "mcpServers": { "yorozu-help": { "command": "npx", "args": ["-y", "<repo>/apps/mcp"] } } }`.

## Run the HTTP server

```sh
pnpm --filter @yorozu/help-mcp start:http    # node src/http.ts
```

It serves stateless Streamable HTTP (POST only, JSON responses) at `<BASE_PATH>/mcp`, also at `<BASE_PATH>` and `<BASE_PATH>/`, and `GET <BASE_PATH>/healthz` returns `{"status":"ok",…}`. Settings come from the environment:

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8790` | Listen port |
| `HOST` | `127.0.0.1` | Listen address; keep it local behind a reverse proxy |
| `BASE_PATH` | empty | Path prefix, for example `/yorozu` |
| `TRUST_PROXY` | `0` | Number of reverse proxies in front. With `1`, the client IP is the last `X-Forwarded-For` entry; with `0` the header is ignored |
| `RATE_LIMIT` | `60` | Requests per client IP per window on the MCP endpoint; more get `429` with `Retry-After`. `/healthz` is not limited |
| `RATE_LIMIT_WINDOW_MS` | `60000` | Rate-limit window |
| `CORS_ORIGINS` | `*` | Allowed browser origins, comma-separated, or `*` |

Request bodies over 64 KB get `413`. A bad value in any variable stops the server with exit code 64.

Behind a reverse proxy at, say, `https://example.com/yorozu`, run it with `BASE_PATH=/yorozu TRUST_PROXY=1` and forward `/yorozu` unchanged (no path stripping) to `127.0.0.1:8790`, letting the proxy append the client address to `X-Forwarded-For`.

## On the website

The website's Cloudflare Worker (`apps/web/worker.mjs`) serves the same server at `https://yorozu.yumi.to/mcp`, with `GET /healthz` as its health check. Both the Worker and `src/http.ts` call `createHandler` from `apps/mcp/src/fetch.ts`, so the tools, resources, prompt, CORS, body limit and rate limit are the same code. The Worker counts requests per `CF-Connecting-IP`, 60 a minute, within each Worker isolate. Cloudflare runs many isolates, so a client can get more than that in total. `deploy-web.yml` redeploys the site when `apps/mcp/src/` changes, so a regenerated bundle goes live on merge.

To try it locally:

```sh
pnpm --filter @yorozu/web build
pnpm --filter @yorozu/web exec wrangler dev    # then POST to http://localhost:8787/mcp
```

## The content bundle

`apps/mcp/scripts/generate.ts` builds `apps/mcp/src/content.json` from the sources above plus the curated files in `apps/mcp/content/` (what each setting, permission and error means). It checks that every curated entry still matches the code: a setting key that no longer exists, a new `@AppStorage` key without a description, or a quoted error message that changed all fail the build. It also fails on anything that looks like personal data (home paths, email addresses, tokens or keys).

The bundle is committed. After changing any doc, the changelog, a setting or a quoted message, regenerate it:

```sh
pnpm --filter @yorozu/help-mcp generate
pnpm --filter @yorozu/help-mcp test          # typecheck: pnpm --filter @yorozu/help-mcp typecheck
```

The `mcp` job in `checks.yml` runs `generate --check` and fails when the committed bundle is stale. Release notes are the exception: the release PR changes only `CHANGELOG.md` and must stay green, so `latest_version` and `changelog` catch up at the next regeneration. Changes only under `apps/mcp/` do not start a Mac or iOS release build; changes under `apps/mcp/src/` redeploy the website.
