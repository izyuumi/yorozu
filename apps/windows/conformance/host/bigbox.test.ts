import assert from "node:assert/strict";
import { randomUUID, createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fakeHost, probe } from "./fake-host.ts";
test("big boxes preserve bytes and UTF-16 send cap refuses before host", async t => {
  const host=await fakeHost(); t.after(()=>host.stop());
  const dir=await mkdtemp(join(tmpdir(),"yorozu-big-"));t.after(()=>rm(dir,{recursive:true,force:true}));
  const p=probe(dir);t.after(()=>p.quit());p.send({cmd:"pair",link:await host.link()});await p.wait(e=>e.ev==="conn" && e.state==="Open");
  // Open fires on the host's peer_info; the Hub broadcasts to us only after handling ours, which the conv_list answer proves.
  await p.wait(e=>e.ev==="list");
  const convId=randomUUID();
  for (const length of [204_800,759_900]) {
    const text="a".repeat(length),messageId=randomUUID();
    host.broadcast([{kind:"reply",data:{convId,messageId,text,ts:Date.now()}}]);
    const reply=await p.wait(e=>e.ev==="reply" && e.messageId===messageId);
    assert.equal(reply.length,length);assert.equal(reply.sha256,createHash("sha256").update(text).digest("hex"));
  }
  const text="語".repeat(60_000);
  p.send({cmd:"send",convId,text});await p.wait(e=>e.ev==="mark" && e.mark==="read");
  assert.equal(host.messages.at(-1)?.text,text);
  const count=host.messages.length;
  p.send({cmd:"send",convId,text:text+"語"});await p.wait(e=>e.ev==="refused" && e.reason==="too_long");
  // Following valid send fences the rejected command at the host boundary.
  const from=p.events.length;p.send({cmd:"send",convId,text:"fence"});await p.wait(e=>e.ev==="mark" && e.mark==="read",from);
  assert.equal(host.messages.length,count+1);assert.equal(host.messages.at(-1)?.text,"fence");
});
