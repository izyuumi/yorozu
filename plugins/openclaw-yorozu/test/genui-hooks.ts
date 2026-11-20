import { existsSync } from "node:fs";
import { registerHooks } from "node:module";

const stub = new URL("./genui-host.js", import.meta.url).href;
const gateway = /\/src\/(runtime|relay|push|retry|activity|attachments|reactions|reads|keys|cron|updates)\.(js|ts)$/;

registerHooks({
  resolve(specifier, context, next) {
    const target = /^(\.|file:)/.test(specifier) && context.parentURL ? new URL(specifier, context.parentURL).href : specifier;
    if (specifier.startsWith("openclaw/") || gateway.test(target)) return { url: stub, shortCircuit: true };
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
