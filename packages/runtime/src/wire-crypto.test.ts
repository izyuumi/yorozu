import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test, vi } from "vitest";
import { deriveChannelKeys, deriveSessionKey, encodeEnvelope, fromBase64Url, generateKeypair,
  helloProof, open, seal, signFrame, toBase64Url, verifyFrame, type YorozuEvent } from "@yorozu/shared";
import { closeSyncHost, retainSyncHost, syncHostRequest } from "./rust-sync.js";
import { WireCrypto } from "./wire-crypto.js";
import { loadKeys } from "./serve.js";
const roots:string[]=[];const leases:(()=>void)[]=[];
function root():string{const dir=mkdtempSync(join(tmpdir(),"yorozu-wire-crypto-"));roots.push(dir);return dir;}
afterEach(()=>{for(const release of leases.splice(0))release();for(const dir of roots.splice(0)){closeSyncHost(dir);rmSync(dir,{recursive:true,force:true});}});
const event:YorozuEvent={id:"original",threadId:"conversation",ts:1700000000000,agentId:"phone",kind:"message",data:{role:"user",text:"a cross-language message"}};
test("production Rust facade interoperates with Node in both live directions, previews, signatures and hello proofs",()=>{
  const dir=root();const original=loadKeys(dir);leases.push(retainSyncHost(dir));const wire=new WireCrypto(dir);const peer=generateKeypair();const pub=toBase64Url(peer.publicKey);wire.validate(pub);
  expect(wire.sessionPub).toEqual(original.session.publicKey);expect(wire.signingPub).toEqual(original.signing.publicKey);
  const keys=deriveChannelKeys(peer.privateKey,wire.sessionPub,"device");
  const outgoing=wire.seal(pub,event,7);expect(JSON.parse(Buffer.from(open(keys.recv,fromBase64Url(outgoing.n),fromBase64Url(outgoing.c))).toString())).toEqual({seq:7,event});
  const incoming=seal(keys.send,encodeEnvelope(9,event));expect(wire.open(pub,{n:toBase64Url(incoming.nonce),c:toBase64Url(incoming.ciphertext)})).toEqual({status:"opened",seq:9,event});
  expect(wire.open(pub,outgoing).status).toBe("unauthenticated");
  const legacy=deriveSessionKey(peer.privateKey,wire.sessionPub);const legacyBox=wire.seal(pub,event);expect(JSON.parse(Buffer.from(open(legacy,fromBase64Url(legacyBox.n),fromBase64Url(legacyBox.c))).toString())).toEqual(event);
  const preview=wire.preview(pub,Buffer.from("private preview"));expect(Buffer.from(open(legacy,fromBase64Url(preview.n),fromBase64Url(preview.c))).toString()).toBe("private preview");
  const frame=Buffer.from("synthetic relay frame");expect(wire.sign(frame)).toEqual(signFrame(original.signing.privateKey,frame));expect(verifyFrame(wire.signingPub,frame,wire.sign(frame))).toBe(true);
  expect(wire.helloProof("synthetic-pairing-proof",pub,toBase64Url(wire.signingPub))).toBe(helloProof("synthetic-pairing-proof",pub,toBase64Url(wire.signingPub)));
});
test("owned crypto child loss preserves generated identity, reconnects and never changes existing key bytes",async()=>{
  const dir=root();const release=retainSyncHost(dir);leases.push(release);const wire=new WireCrypto(dir);const bytes=readFileSync(join(dir,"keys.json"));const pid=syncHostRequest(dir,{op:"bridge_pid"}).pid as number;process.kill(pid,"SIGKILL");
  await vi.waitFor(()=>{const restored=new WireCrypto(dir);expect(restored.sessionPub).toEqual(wire.sessionPub);expect(restored.signingPub).toEqual(wire.signingPub);});
  expect(readFileSync(join(dir,"keys.json"))).toEqual(bytes);const peer=generateKeypair();wire.validate(toBase64Url(peer.publicKey));expect(wire.seal(toBase64Url(peer.publicKey),event,1).c.length).toBeGreaterThan(16);
});
test("missing identity alongside saved pairings blocks facade readiness and retains connection bytes",()=>{
  const dir=root();const saved='[{"pub":"saved-connection","future":true}]\n';writeFileSync(join(dir,"devices.json"),saved);leases.push(retainSyncHost(dir));expect(()=>new WireCrypto(dir)).toThrow("Restore the saved identity or check storage access");expect(readFileSync(join(dir,"devices.json"),"utf8")).toBe(saved);
});
