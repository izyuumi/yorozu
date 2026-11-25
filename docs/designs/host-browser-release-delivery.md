# Host and browser release delivery

Design note. Nothing here is implemented.

## Problem

The browser client and the host plugin ship on separate tracks:

- `release-host.yml` runs the plugin tests and uploads a tarball artifact of `plugins/openclaw-yorozu` at the release commit. Nothing installs it.
- The owner's always-on Gateway loads the plugin straight from its checkout under `~/Projects/yorozu`, so the host runs whatever that checkout was last pulled to.
- The browser client goes live through `browser-client.yml` (`workflow_dispatch`, staging or production). The standing practice is to deploy after every web merge, so merging a change under `apps/web/browser` starts the browser deploy today.

The browser can therefore reach users before the host can serve it. Browser QR pairing shows the result: a browser built after 56a4d699 asks for `pair-browser-invite`, and a host still on an older checkout (or with `YOROZU_BROWSER_EPHEMERAL` unset) never answers. The phone says the host plugin is too old, and the browser says "Nothing arrived?" after a minute.

## Option A: host updater on the owner's explicit go

A small command on the Gateway machine that, when the owner runs it:

1. Fetches `main` into `~/Projects/yorozu` with `git pull --ff-only`, refusing if the checkout is dirty or has diverged.
2. Runs the plugin tests (`node --test 'plugins/openclaw-yorozu/test/*.test.ts'`).
3. Restarts the Gateway and prints the commit it now runs and its `PeerInfo` capabilities.

It never runs on a schedule or a webhook. Under the repo's language rules a standalone tool is Swift (or Rust if it becomes a long-running process); a few lines of shell inside `scripts/` would also do for a one-shot command.

- Upside: the host is brought up to date in one step, and the owner decides when the Gateway restarts.
- Downside: it does not stop the browser from going out first. The gap shrinks only as fast as the owner runs it.

## Option B: block the browser deploy until the host matches

The browser deploy job checks the live host before it publishes. The host would report the commit it was loaded from (for example a `hostCommit` field next to `hostVersion` in `PeerInfo`, or a line in `openclaw channels status`). The deploy compares that with the commit being deployed, or at least confirms that every capability the browser needs (today `pair-browser-invite`) is advertised, and fails with a clear message if not.

- Upside: the browser can never be ahead of the host. The failure mode is "deploy refused", not "users see a broken pairing screen".
- Downside: CI needs a way to ask the live host, which runs on the owner's machine behind the relay. That means either a CI identity paired with the host or the owner running the check locally and passing its result to the dispatch. It also adds a wire field, which goes through the relay contract.

## Recommendation

Option A first. It is small, it needs no new wire field and no CI access to the host, and it keeps every Gateway restart under the owner's control. Pair it with one manual rule in the release checklist: run the updater before dispatching a production browser deploy that needs a new host capability. If the browser keeps shipping ahead of the host after that, add Option B's capability check, starting with a version the owner runs locally before dispatching.
