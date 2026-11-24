import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { ownerRuntime } from "./conversation-owner-fixture.ts";

const sdk = process.env.YOROZU_OPENCLAW_SDK;
const sdkPrefix = "openclaw/plugin-sdk/";
const relay = new URL("../../../apps/relay/src/index.ts", import.meta.url);
const browser = new URL("../../../apps/web/browser/src/", import.meta.url);
const source = new URL("../src/", import.meta.url);
const hosted = process.env.YOROZU_BROWSER_TEST_HOSTED === "1";
const skip = !sdk || !existsSync(path.join(sdk, "dist/plugin-sdk/websocket-runtime.js"))
  ? "set YOROZU_OPENCLAW_SDK to the installed OpenClaw package root"
  : !existsSync(new URL("../../../apps/web/browser/node_modules/@noble/ciphers", import.meta.url))
    ? "install browser dependencies"
    : !existsSync(new URL("../../../apps/relay/node_modules/ws", import.meta.url)) ? "install relay dependencies" : false;

test("real plugin registers v4 browser through the relay, resumes after restart, and enforces role/revocation", { skip, timeout: hosted ? 120_000 : 30_000 }, async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "yorozu-browser-plugin-"));
  const before = { HOME: process.env.HOME, OPENCLAW_STATE_DIR: process.env.OPENCLAW_STATE_DIR, YOROZU_BROWSER_EPHEMERAL: process.env.YOROZU_BROWSER_EPHEMERAL };
  Object.assign(process.env, { HOME: root, OPENCLAW_STATE_DIR: root, YOROZU_BROWSER_EPHEMERAL: "1" });
  const hooks = registerHooks({ resolve(specifier, context, next) {
    if (specifier.startsWith(sdkPrefix)) return next(pathToFileURL(path.join(sdk!, "dist/plugin-sdk", `${specifier.slice(sdkPrefix.length)}.js`)).href, context);
    if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  } });
  t.after(async () => {
    hooks.deregister();
    for (const [key,value] of Object.entries(before)) if (value === undefined) delete process.env[key]; else process.env[key] = value;
    await rm(root,{recursive:true,force:true});
  });
  const { resolveStateDir } = await import(sdkPrefix + "state-paths");
  assert.equal(path.resolve(resolveStateDir()), path.resolve(root));
  const owner = await ownerRuntime(source);
  const { runRelayHost, beginPairing, unpairDevice, broadcast } = await import(new URL("relay.ts", source).href);
  const { b64u, ed25519Keypair, roomId, x25519Keypair } = await import(new URL("wire.ts", source).href);
  const { connect } = await import(new URL("connection.mjs", browser).href);
  const { makeIdentity } = await import(new URL("wire.mjs", browser).href);
  const { parsePairing } = await import(new URL("pairing.mjs", browser).href);
  const url = process.env.YOROZU_BROWSER_TEST_REMOTE_RELAY;
  const server = url ? undefined : await (await import(relay.href)).startRelay(0);
  const relayURL = url ?? `ws://127.0.0.1:${server.port}/`;
  const signing = ed25519Keypair();
  const keys = { signing, static: x25519Keypair(), room: roomId(signing.publicKey) };
  let host;
  let connection;
  let status, browserStatus, saved, removed;
  const hostEvents: string[] = [];
  const threads = new Map();
  const events: any[] = [];
  const waitFor = async (read: () => any, description: string) => {
    const until = Date.now() + 8_000;
    while (!read()) {
      if (Date.now() > until) throw Error("Timed out: " + description);
      await delay(20);
    }
  };
  function start() {
    status = null;
    const controller = new AbortController();
    const task = runRelayHost({
      log: process.env.YOROZU_BROWSER_TEST_DEBUG ? {info:(v)=>{if (!/registered at relay/.test(v)) console.error(v);},warn:(v)=>console.error(v)} : undefined,
      relayUrl:relayURL, keys, signal:controller.signal, mediaMaxBytes:1024,
      onStatus(value) { status = value; },
      onMessage(message) {
        hostEvents.push(message.text);
        const ts = Date.now();
        const reply = {convId:message.convId,messageId:randomUUID(),text:"Preview received: "+message.text,ts};
        threads.set(message.convId, [
          {kind:"user",id:message.messageId,seq:1,ts,text:message.text},
          {kind:"agent",id:reply.messageId,seq:2,ts,text:reply.text},
        ]);
        broadcast([{kind:"reply",data:reply}]);
      },
      onReaction() { throw Error("browser should not invoke reaction"); },
      async onRequest(event) {
        if (event.kind === "conv_list") return {kind:"conv_list",data:{conversations:[...threads.keys()].map(
          (convId) => ({convId,updatedAt:Date.now(),rev:2}))}};
        if (event.kind === "history" && !("items" in event.data)) {
          return {kind:"history",data:{...event.data,items:threads.get(event.data.convId) ?? [],more:false,rev:2}};
        }
        throw Error("unexpected browser request " + event.kind);
      },
    });
    void task.catch(() => {});
    return { async stop() { controller.abort(); await task; } };
  }
  try {
    host = start();
    await waitFor(() => status?.connected, "register");
    const invite = await beginPairing(true);
    const device = { ...parsePairing(invite.link, new URL(relayURL).href), identity: await makeIdentity(true) };
    const signingPub = b64u(device.identity.signingPublic);
    const browserHooks = {
      status(value) { browserStatus=value; },
      event(value) { events.push(value); },
      async paired(record) { saved=structuredClone(record); },
      removed(reason) { removed=reason; },
    };
    connection = connect(device,browserHooks);
    await waitFor(() => browserStatus==="Connected", "browser authenticated and confirmed");
    const entry = owner.stores.get("devices")?.get(signingPub);
    assert.equal(entry?.browser, true);
    assert.equal(entry?.staticPub, undefined);
    assert.equal(saved.identity.signingPrivate.extractable,false);
    assert.equal(saved.identity.noisePrivate,undefined);
    assert.equal(saved.secret,undefined);
    assert.equal(saved.token,undefined);
    const allowed = {convId:"055890de-de0f-48be-88f3-5e009fd04491",messageId:"055890de-de0f-48be-88f3-5e009fd04492",text:"isolated browser chat"};
    const denied = {id:signingPub,removed:true};
    await connection.send("message",allowed);
    await waitFor(() => hostEvents.length === 1,"chat at host");
    await connection.send("device_patch",denied);
    await connection.send("pair_invite",{});
    await connection.send("message", {...allowed, messageId:"055890de-de0f-48be-88f3-5e009fd04494",
      attachments:[{id:"055890de-de0f-48be-88f3-5e009fd04495",name:"synthetic.txt",mime:"text/plain",size:10}]});
    await connection.send("message", {...allowed, messageId:"055890de-de0f-48be-88f3-5e009fd04496", replyTo:{messageId:allowed.messageId}});
    await connection.send("message", {...allowed, messageId:"055890de-de0f-48be-88f3-5e009fd04497", extraField:"reject"});
    await waitFor(() => events.filter((e) => e.kind === "error" && e.data.code === "unsupported").length === 5,"admin and nontext message fields rejected");
    assert.equal(owner.stores.get("devices")?.get(signingPub)?.browser, true);
    connection.close();
    await host.stop();
    host = start();
    await waitFor(() => status?.connected,"host restart");
    connection = connect(saved,{...browserHooks, async paired() { assert.fail("should not complete a new pairing"); }});
    await waitFor(() => browserStatus === "Connected","resume from signing key");
    assert.equal(await unpairDevice(signingPub),true);
    await waitFor(() => removed,"live revocation");
    assert.equal(await connection.send("message",{...allowed,messageId:"055890de-de0f-48be-88f3-5e009fd04493"}),false);
    assert.deepEqual(hostEvents,[allowed.text]);
    assert.equal(owner.stores.get("devices")?.has(signingPub),false);
    if (hosted) {
      assert.equal(new URL(relayURL).hostname,"yorozu-browser-test-relay.yumi-f4f.workers.dev");
      const {webkit,devices} = await import(new URL("../node_modules/playwright-core/index.mjs", browser).href);
      const profile = path.join(root,"browser-profile");
      let context;
      const launch = () => webkit.launchPersistentContext(profile,{...devices["iPhone 15"],defaultBrowserType:undefined});
      const visible = (page,text) => page.getByText(text,{exact:true}).first().waitFor({timeout:12_000});
      const {webLink} = await beginPairing(true);
      const site = new URL(webLink).origin;
      assert.equal(site,"https://yorozu-v4-staging.yumi-f4f.workers.dev");
      try {
        context = await launch();
        let page = context.pages()[0];
        const pageDiagnostics: string[] = [];
        page.on("pageerror",e=>pageDiagnostics.push(e.name+":"+e.message));
        page.on("console",m=>{if(m.type()==="error")pageDiagnostics.push(m.text());});
        const response = await page.goto(webLink);
        assert.equal(response?.status(),200);
        assert.match(response.headers()["content-security-policy"], /connect-src wss:\/\/yorozu-browser-test-relay\.yumi-f4f\.workers\.dev;/);
        await visible(page,"Pairing link ready.");
        assert.equal(new URL(page.url()).hash,"");
        await page.getByRole("button",{name:"Continue"}).tap();
        await page.getByRole("heading",{name:"Confirm host fingerprint"}).waitFor();
        await page.getByRole("button",{name:"Cancel"}).tap();
        const input = page.getByLabel("Pairing link");
        await input.tap();
        await input.evaluate((field, link) => {
          const contents = new DataTransfer();
          contents.setData("text/plain", ["```text", link, "```"].join("\n"));
          field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: contents, bubbles:true, cancelable:true }));
        }, webLink);
        await page.getByRole("button",{name:"Continue"}).tap();
        await page.getByRole("heading",{name:"Confirm host fingerprint"}).waitFor();
        await page.getByRole("button",{name:"Pair",exact:true}).click();
        try { await visible(page,"Connected"); } catch(error) {
          console.error({origin:new URL(page.url()).origin, state:await page.evaluate(() => ({title:document.title, status:document.querySelector("#connection")?.textContent, notice:document.querySelector("#notice")?.textContent})).catch(() => ({})),pageDiagnostics});
          throw error;
        }
        await page.getByLabel("Message",{exact:true}).fill("Hosted browser transport");
        await page.getByRole("button",{name:"Send",exact:true}).click();
        await visible(page,"Preview received: Hosted browser transport");
        await context.close();
        await host.stop();
        context = await launch();
        page = context.pages()[0];
        await page.goto(site);
        await visible(page,"Mac is offline");
        host = start();
        await waitFor(() => status?.connected,"hosted host restart");
        await visible(page,"Connected");
        const id = [...(owner.stores.get("devices")?.keys() ?? [])][0];
        assert.ok(id);
        const storage = await page.evaluate(async () => {
          const db = await new Promise((yes) => {const req = indexedDB.open("yorozu-pairing",1);req.onsuccess=()=>yes(req.result);});
          const record = await new Promise((yes) => {const req=db.transaction("devices").objectStore("devices").get("current");req.onsuccess=()=>yes(req.result);});
          db.close();
          return {privateExtractable:record.identity.signingPrivate.extractable,noise:!!record.identity.noisePrivate,invite:!!(record.token||record.secret)};
        });
        assert.deepEqual(storage,{privateExtractable:false,noise:false,invite:false});
        await unpairDevice(id);
        await visible(page,"This browser was removed from your Mac");
      } finally { await context?.close(); }
    }
  } finally {
    connection?.close();
    await host?.stop();
    await server?.close();
    await owner.close();
  }
});
