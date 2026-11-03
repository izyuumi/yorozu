// Renders AppPreview per locale, then finishes it to App Store Connect's app preview spec:
// artifacts/app-preview/<locale>/yorozu-preview-886x1920.mp4 and poster-5s.png (frame 150, ASC's default poster).
// Usage: pnpm --filter @yorozu/preview render [en-US] [ja]
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkg = join(dirname(fileURLToPath(import.meta.url)), "..");
const root = join(pkg, "../..");
const scenes = ["hook", "lockscreen", "approve", "talk", "list"];
const run = (command: string, args: string[]) => execFileSync(command, args, { cwd: pkg, stdio: "inherit" });

const encoders = execFileSync("ffmpeg", ["-hide_banner", "-encoders"], { encoding: "utf8" });
const audio = /^\s*A\S*\s+aac_at\s/m.test(encoders)
  ? ["-c:a", "aac_at", "-aac_at_mode", "cbr", "-b:a", "256k"]
  : ["-c:a", "aac", "-b:a", "256k"];

const locales = process.argv.length > 2 ? process.argv.slice(2) : ["en-US", "ja"];
for (const locale of locales) {
  const missing = scenes.map((s) => join(pkg, "footage", locale, `${s}.mp4`)).filter((f) => !existsSync(f));
  if (missing.length) throw new Error(`Missing takes (run scripts/app_preview_capture.sh):\n${missing.join("\n")}`);

  const out = join(root, "artifacts/app-preview", locale);
  mkdirSync(out, { recursive: true });
  const master = join(out, "master.mov");
  const final = join(out, "yorozu-preview-886x1920.mp4");
  run(join(pkg, "node_modules/.bin/remotion"), [
    "render", "src/index.ts", "AppPreview", master,
    `--props=${JSON.stringify({ locale })}`, "--codec=prores", "--prores-profile=hq", "--image-format=png",
  ]);
  run("ffmpeg", [
    "-y", "-hide_banner", "-loglevel", "warning",
    "-i", master, "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
    "-map", "0:v:0", "-map", "1:a:0", "-shortest",
    "-r", "30", "-c:v", "libx264", "-profile:v", "high", "-level:v", "4.0", "-pix_fmt", "yuv420p",
    "-b:v", "11M", "-minrate", "11M", "-maxrate", "11M", "-bufsize", "11M", "-x264-params", "nal-hrd=cbr",
    ...audio, "-ar", "48000", "-ac", "2",
    "-movflags", "+faststart", final,
  ]);
  run("ffmpeg", ["-y", "-hide_banner", "-loglevel", "warning", "-i", final, "-vf", "select=eq(n\\,150)", "-frames:v", "1", join(out, "poster-5s.png")]);
  rmSync(master);
  console.log(`${locale}: ${final}`);
}
