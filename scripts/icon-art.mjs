// Draws the Yorozu app icon: a noren (暖簾), the split shop curtain a 万屋 hangs out front.
//
// One generator rather than a dozen hand-kept SVGs: the geometry below is the single copy
// of the drawing, and each appearance (light / dark / tinted) is the same paths in a
// different palette. Run it after changing anything here:
//
//   node scripts/icon-art.mjs
//
// It writes the layer SVGs that apps/ios/Resources/AppIcon.icon references, and — given a
// directory argument — one flat composite SVG per appearance for scripts/icon-render.sh to
// rasterise into the docs previews, the splash image and the Mac .icns.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const assets = join(root, "apps/ios/Resources/AppIcon.icon/Assets");

// --- geometry, on the 1024pt canvas Icon Composer draws every layer into ----------------
const ROD = { x0: 150, x1: 874, y0: 286, y1: 330, r: 22 };
const LOOP = { w: 92, y0: 252, y1: 376, r: 18, cx: [268, 512, 756] };
// The panels tuck up behind the rod rather than starting below it, so no seam shows.
const PANEL = { top: 300, bot: 742, w: 200, gap: 44, x0: 168 };
const panelX = (i) => PANEL.x0 + i * (PANEL.w + PANEL.gap);

// A hanging cloth: the sides pinch in a little below the rod and flare back out at the
// hem, and the hem itself sags. Nothing here is a rectangle, which is what keeps it
// reading as fabric at 40pt rather than as three bookmarks.
const cloth = (x0, x1, top, bot, { flare = 12, pinch = 5, sag = 11 } = {}) => {
  const h = bot - top;
  return [
    `M${x0} ${top}`,
    `L${x1} ${top}`,
    `C${x1 - pinch} ${top + h * 0.45} ${x1 + flare * 0.5} ${bot - h * 0.3} ${x1 + flare} ${bot}`,
    `Q${(x0 + x1) / 2} ${bot + sag} ${x0 - flare} ${bot}`,
    `C${x0 - flare * 0.5} ${bot - h * 0.3} ${x0 + pinch} ${top + h * 0.45} ${x0} ${top}`,
    "Z",
  ].join(" ");
};

// The rightmost panel is caught mid-lift: its hem has rolled forward into a cone and you
// are looking straight into the opening. `curlBody` is the cloth, whose hem runs into the
// rim of that opening; `curlMouth` is the opening itself, drawn over the top of it.
const CURL = { cx: 110, cy: 30, rx: 64, ry: 26, tilt: -22 };
const mouthRim = (x0, bot) => {
  const t = (CURL.tilt * Math.PI) / 180;
  const [cx, cy] = [x0 + CURL.cx, bot - CURL.cy];
  const at = (s) => [cx + s * CURL.rx * Math.cos(t), cy + s * CURL.rx * Math.sin(t)];
  return { right: at(1), left: at(-1) };
};
const curlBody = (x0, x1, top, bot) => {
  const h = bot - top;
  const { right, left } = mouthRim(x0, bot);
  return [
    `M${x0} ${top}`,
    `L${x1} ${top}`,
    `C${x1 - 5} ${top + h * 0.45} ${x1 + 6} ${bot - h * 0.3} ${x1 + 12} ${bot}`,
    // the hem, sweeping right to left and lifting into the rim of the opening
    `C${x1 - 46} ${bot + 14} ${right[0] + 26} ${bot - 8} ${right[0]} ${right[1]}`,
    `Q${x0 + CURL.cx} ${bot - CURL.cy - CURL.ry - 4} ${left[0]} ${left[1]}`,
    // and back up the left edge, which the roll has pulled inwards
    `C${x0 + 30} ${bot - h * 0.45} ${x0 + 4} ${top + h * 0.45} ${x0} ${top}`,
    "Z",
  ].join(" ");
};
const curlMouth = (x0, bot) =>
  `cx="${x0 + CURL.cx}" cy="${bot - CURL.cy}" rx="${CURL.rx}" ry="${CURL.ry}" transform="rotate(${CURL.tilt} ${x0 + CURL.cx} ${bot - CURL.cy})"`;
// The crease running up out of the roll, which is what says "cloth" rather than "funnel".
const curlCrease = (x0, bot) =>
  `M${x0 + 58} ${bot - 56} C${x0 + 66} ${bot - 140} ${x0 + 108} ${bot - 196} ${x0 + 152} ${bot - 262}`;

// --- palettes ---------------------------------------------------------------------------
// Tinted is greyscale on purpose: the system reads its luminance and applies the user's
// tint, so the only decision left here is how the parts rank against each other.
const CLOTH = {
  loop: "#FFFAEC",
  cloth: "#F4E5BF",
  clothEdge: "#EFDCAE",
  lip: "#FFFAEA",
};
const PALETTES = {
  light: {
    bg: "#F5B82E",
    rod: "#D19A57",
    rodTop: "#E6BC82",
    rodEnd: "#B07C3C",
    ...CLOTH,
  },
  // Only the background and the rod change in the dark appearance: icon.json points the
  // cloth layers at the same SVGs it uses for light, so the cloth colours here have to be
  // the light ones or the preview would not be showing what actually ships.
  dark: {
    bg: "#171B33",
    rod: "#9E8360",
    rodTop: "#B79C77",
    rodEnd: "#7C6544",
    ...CLOTH,
  },
  tinted: {
    bg: "#000000",
    rod: "rgba(255,255,255,0.62)",
    rodTop: "rgba(255,255,255,0.78)",
    rodEnd: "rgba(255,255,255,0.48)",
    loop: "rgba(255,255,255,1)",
    cloth: "rgba(255,255,255,0.8)",
    clothEdge: "rgba(255,255,255,0.66)",
    lip: "#FFFFFF",
  },
};

// --- layers -------------------------------------------------------------------------------
// Each is a complete standalone SVG: Icon Composer wants one file per layer so it can give
// each its own shadow and specular pass.
const svg = (body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n${body}\n</svg>\n`;

const rod = (c) => `  <g>
    <rect x="${ROD.x0}" y="${ROD.y0}" width="${ROD.x1 - ROD.x0}" height="${ROD.y1 - ROD.y0}" rx="${ROD.r}" fill="${c.rod}"/>
    <rect x="${ROD.x0 + 10}" y="${ROD.y0 + 7}" width="${ROD.x1 - ROD.x0 - 20}" height="11" rx="5.5" fill="${c.rodTop}"/>
    <rect x="${ROD.x0}" y="${ROD.y0}" width="26" height="${ROD.y1 - ROD.y0}" rx="${ROD.r}" fill="${c.rodEnd}"/>
    <rect x="${ROD.x1 - 26}" y="${ROD.y0}" width="26" height="${ROD.y1 - ROD.y0}" rx="${ROD.r}" fill="${c.rodEnd}"/>
  </g>`;

const loops = (c) => `  <g fill="${c.loop}">
${LOOP.cx
  .map(
    (cx) =>
      `    <rect x="${cx - LOOP.w / 2}" y="${LOOP.y0}" width="${LOOP.w}" height="${LOOP.y1 - LOOP.y0}" rx="${LOOP.r}"/>`,
  )
  .join("\n")}
  </g>`;

const panels = (c) => {
  const flat = [0, 1]
    .map((i) => {
      const x0 = panelX(i);
      return `    <path d="${cloth(x0, x0 + PANEL.w, PANEL.top, PANEL.bot)}" fill="${c.cloth}"/>`;
    })
    .join("\n");
  const x0 = panelX(2);
  return `  <g>
${flat}
    <path d="${curlBody(x0, x0 + PANEL.w, PANEL.top, PANEL.bot)}" fill="${c.cloth}"/>
    <path d="${curlCrease(x0, PANEL.bot)}" fill="none" stroke="${c.clothEdge}" stroke-width="5" stroke-linecap="round" opacity="0.75"/>
    <ellipse ${curlMouth(x0, PANEL.bot)} fill="${c.lip}"/>
    <ellipse ${curlMouth(x0, PANEL.bot)} fill="none" stroke="${c.clothEdge}" stroke-width="6"/>
  </g>`;
};

// Back to front: SVG paints in document order, so this is the icon.json group list
// reversed. The rod hangs behind the cloth; the loops sit in front of both.
const stack = (c) => [rod(c), panels(c), loops(c)].join("\n");

const write = (p, s) => (mkdirSync(dirname(p), { recursive: true }), writeFileSync(p, s));

// Light and dark share the cloth — only the rod desaturates — so there is no -dark cloth.
// (PALETTES.dark spreads the light cloth back in, so the previews agree with that.)
write(join(assets, "rod.svg"), svg(rod(PALETTES.light)));
write(join(assets, "rod-dark.svg"), svg(rod(PALETTES.dark)));
write(join(assets, "rod-tinted.svg"), svg(rod(PALETTES.tinted)));
write(join(assets, "loops.svg"), svg(loops(PALETTES.light)));
write(join(assets, "loops-tinted.svg"), svg(loops(PALETTES.tinted)));
write(join(assets, "panels.svg"), svg(panels(PALETTES.light)));
write(join(assets, "panels-tinted.svg"), svg(panels(PALETTES.tinted)));

// The composites are the flat previews: no glass, no specular, just the artwork on its
// background, which is all a docs screenshot or the splash image needs.
const out = process.argv[2];
if (out) {
  for (const [name, c] of Object.entries(PALETTES)) {
    write(
      join(out, `icon-${name}.svg`),
      svg(`  <rect width="1024" height="1024" fill="${c.bg}"/>\n${stack(c)}`),
    );
  }
  // The Mac build has no asset catalog to compile the .icon into, so its .icns carries the
  // rounded shape baked in: the 824pt body on the 1024pt canvas that macOS icons use. No
  // clip path needed — every part of the drawing already sits inside that inset.
  const inset = 100;
  const k = (1024 - inset * 2) / 1024;
  write(
    join(out, "icon-macos.svg"),
    svg(
      `  <rect x="${inset}" y="${inset}" width="${1024 - inset * 2}" height="${1024 - inset * 2}" rx="185" fill="${PALETTES.light.bg}"/>\n` +
        `  <g transform="translate(${inset} ${inset}) scale(${k})">\n${stack(PALETTES.light)}\n  </g>`,
    ),
  );
}
