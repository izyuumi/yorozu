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
//
// The cloth is meant to read as translucent linen lit from behind: almost as yellow as the
// background through its middle, creamy where it folds towards the light, and rimmed by a
// thin bright edge all the way round. That is done with gradients rather than flat fills —
// CoreSVG (which is what both Icon Composer and the NSImage rasteriser in
// scripts/icon-render.sh use) handles gradients, stop-opacity and feGaussianBlur.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const assets = join(root, "apps/ios/Resources/AppIcon.icon/Assets");

// --- geometry, on the 1024pt canvas Icon Composer draws every layer into ----------------
// The whole arrangement sits a touch above centre, with a wide margin all round, so it
// still has air inside the rounded mask at small sizes.
const ROD = { x0: 118, x1: 906, y0: 275, y1: 321, r: 23 };
const LOOP = { w: 84, y0: 246, y1: 352, r: 20 };

// Panels nearly touch under the rod and splay apart towards the hem: the slits between
// them widen from 8pt to 34pt, which is what gives the group its trapezoid silhouette.
// They hang off the underside of the rod, overlapping it by a hair so no seam shows, and
// the loops bridge the join.
const PANEL = { top: 316, bot: 760 };
const TOPS = [
  [172, 393],
  [401, 622],
  [630, 851],
];
const LEAN = 54; // how far the outer panels swing away from the middle at the hem
const FLARE = 18; // how much wider each panel gets at the hem
const hemOf = (i) => {
  const s = i - 1;
  return [TOPS[i][0] + s * LEAN - FLARE, TOPS[i][1] + s * LEAN + FLARE];
};
const loopCx = (i) => (TOPS[i][0] + TOPS[i][1]) / 2;

// A hanging cloth: it drops nearly straight from the rod, pinching in by a few points, and
// only swings out over the last third into a sagging hem. Nothing here is a rectangle,
// which is what keeps it reading as fabric at 40pt rather than as three bookmarks.
const PINCH = 3;
const SAG = 18;
// An edge is a cubic from the rod down to the hem; halfway down is where the cross-panel
// shading is measured from, so it lines up with the cloth however far the panel leans.
const edge = (xTop, xBot, dir) => [xTop, xTop + dir * PINCH, xTop + (xBot - xTop) * 0.55, xBot];
const midX = ([a, b, c, d]) => (a + 3 * b + 3 * c + d) / 8;
const cloth = ([tl, tr], [bl, br], top = PANEL.top, bot = PANEL.bot) => {
  const h = bot - top;
  const [r0, r1, r2, r3] = edge(tr, br, -1);
  const [l0, l1, l2, l3] = edge(tl, bl, 1);
  return [
    `M${l0} ${top}`,
    `L${r0} ${top}`,
    `C${r1} ${top + h * 0.42} ${r2} ${top + h * 0.8} ${r3} ${bot}`,
    `Q${(bl + br) / 2} ${bot + SAG} ${l3} ${bot}`,
    `C${l2} ${top + h * 0.8} ${l1} ${top + h * 0.42} ${l0} ${top}`,
    "Z",
  ].join(" ");
};
// Where the cloth actually spans, halfway down, for each panel.
const SPAN = [0, 1, 2].map((i) =>
  i === 2
    ? [693, 867]
    : [midX(edge(TOPS[i][0], hemOf(i)[0], 1)), midX(edge(TOPS[i][1], hemOf(i)[1], -1))],
);
// The glossy band: a slim panel-shaped sliver riding a fifth of the way in from the left
// edge, drawn as its own shape so it tracks the lean rather than the bounding box.
const sheenBand = (i) => {
  const [tl, tr] = TOPS[i];
  const [bl, br] = hemOf(i);
  const at = (a, b, f) => [a + (b - a) * f[0], a + (b - a) * f[1]];
  return cloth(at(tl, tr, [0.09, 0.23]), at(bl, br, [0.09, 0.23]));
};

// The rightmost panel is caught mid-lift: its hem has rolled forward into a cone and you
// are looking straight into the opening. The roll pulls the left edge inwards and shortens
// the panel, so the silhouette narrows towards the mouth instead of flaring like the
// others. Three points carry the whole illusion —
//   L  the left lip of the opening, where the left edge finally lands
//   R  the right lip, where the right edge lands
//   P  the fold: the cusp where the cloth doubles back over itself
// The hem runs L → R the long way round, below both, and the crease climbs out of P.
const CURL = { L: [756, 756], R: [903, 724], P: [826, 676], hemQ: [818, 856] };
const curlBody = () => {
  const [tl, tr] = TOPS[2];
  const { L, R, hemQ } = CURL;
  const h = PANEL.bot - PANEL.top;
  return [
    `M${tl} ${PANEL.top}`,
    `L${tr} ${PANEL.top}`,
    `C${tr - 3} ${PANEL.top + h * 0.42} ${tr + 29} ${PANEL.top + h * 0.8} ${R[0]} ${R[1]}`,
    `Q${hemQ[0]} ${hemQ[1]} ${L[0]} ${L[1]}`,
    `C${L[0] - 30} ${L[1] - 92} ${tl + 20} ${PANEL.top + h * 0.4} ${tl} ${PANEL.top}`,
    "Z",
  ].join(" ");
};
// The opening: same hem below, and above it the two edges of the roll meeting at the fold.
const curlMouth = () => {
  const { L, R, P, hemQ } = CURL;
  return [
    `M${L[0]} ${L[1]}`,
    `Q${hemQ[0]} ${hemQ[1]} ${R[0]} ${R[1]}`,
    `C${R[0] - 17} ${R[1] - 24} ${R[0] - 45} ${R[1] - 42} ${P[0]} ${P[1]}`,
    `C${P[0] - 30} ${P[1] + 14} ${L[0] + 16} ${L[1] - 40} ${L[0]} ${L[1]}`,
    "Z",
  ].join(" ");
};
// The crease running up out of the roll, which is what says "cloth" rather than "funnel".
const curlCrease = () =>
  `M${CURL.P[0]} ${CURL.P[1]} C${CURL.P[0] - 30} ${CURL.P[1] - 74} ${CURL.P[0] - 88} ${CURL.P[1] - 172} ${CURL.P[0] - 142} ${CURL.P[1] - 288}`;

// --- palettes ---------------------------------------------------------------------------
// Every part is a stop list rather than a flat colour, because the shading *is* the
// drawing here. `cloth` runs across a panel (left rim, specular band, translucent middle,
// right rim); `shade` and `glow` are overlays painted back over the same path.
//
// Tinted is white-on-nothing on purpose: the system reads the layer's luminance and
// applies the user's tint, so the only decision left is how the parts rank against each
// other — which is exactly what the alpha ramps below encode.
const w = (a) => ["#FFFFFF", a];
const CLOTH = {
  // across the panel: bright rim, a glossy band a fifth of the way in, then the
  // translucent body, which is barely lighter than the background it is lit through.
  cloth: [
    [0, "#FFFAE8"],
    [0.04, "#FCF0D2"],
    [0.11, "#F8E6B9"],
    [0.18, "#FFFCEF"],
    [0.26, "#FADFA8"],
    [0.38, "#F5D389"],
    [0.52, "#EFC873"],
    [0.7, "#F0C66E"],
    [0.88, "#F6D078"],
    [1, "#FDDE92"],
  ],
  // the glossy band a fifth of the way in, repainted over the warm pass so the warm pass
  // cannot dull it, plus the sliver of sheen that catches the far edge.
  sheen: [
    [0, "#FFFFFF", 0],
    [0.34, "#FFFFFF", 0.5],
    [0.52, "#FFFFFF", 0.58],
    [1, "#FFFFFF", 0],
  ],
  // down the panel: the middle is where the cloth is flattest and most saturated.
  shade: [
    [0, "#DC960A", 0],
    [0.18, "#DC960A", 0.12],
    [0.5, "#DC960A", 0.26],
    [0.76, "#DC960A", 0.34],
    [0.92, "#DC960A", 0.2],
    [1, "#DC960A", 0],
  ],
  // and the light coming under the hem.
  glow: [
    [0, "#FFDC85", 0],
    [0.82, "#FFDC85", 0],
    [0.9, "#FFE49B", 0.45],
    [1, "#FFF3CE", 0.92],
  ],
  rim: [
    [0, "#FFFCEB", 0.55],
    [0.4, "#FFFDF0", 0.9],
    [1, "#FFFFF6", 1],
  ],
  mouth: [
    [0, "#E7A337"],
    [0.4, "#F8C462"],
    [1, "#FFE6A2"],
  ],
  // the far wall of the cone, where no light reaches round the fold.
  deep: [
    [0, "#A5671A", 0.42],
    [0.55, "#A5671A", 0],
  ],
  mouthRim: "rgba(255,253,240,0.95)",
  crease: [
    [0, "#FFFEF5", 1],
    [0.35, "#FFFBE9", 0.6],
    [1, "#FFFBE9", 0],
  ],
  loop: [
    [0, "#FAF7DC"],
    [0.12, "#FFFAEF"],
    [0.35, "#FCEED6"],
    [0.55, "#F5D5A8"],
    [0.72, "#E9C489"],
    [0.88, "#F3CE8C"],
    [1, "#FFF0CC"],
  ],
  // the loop is a tube seen end-on: both sides fall away from the light.
  loopSide: [
    [0, "#C08838", 0.26],
    [0.2, "#C08838", 0],
    [0.8, "#C08838", 0],
    [1, "#C08838", 0.3],
  ],
  loopShadow: "rgba(150,95,10,0.28)",
};
const WOOD = {
  rod: [
    [0, "#D9A552"],
    [0.1, "#F7EAD4"],
    [0.2, "#F8D3A0"],
    [0.35, "#F6CE8C"],
    [0.48, "#EEB86F"],
    [0.62, "#DD9F51"],
    [0.8, "#C7842F"],
    [1, "#B06C1E"],
  ],
  cap: [
    [0, "#E5B771"],
    [0.4, "#D09A4E"],
    [1, "#A4661B"],
  ],
};
const PALETTES = {
  light: {
    bg: [
      [0, "#F6BC3A"],
      [1, "#F5B82E"],
    ],
    shadow: "rgba(124,78,8,0.24)",
    ...WOOD,
    ...CLOTH,
  },
  // Only the background, the rod and the shadow change in the dark appearance: icon.json
  // points the cloth layers at the same SVGs it uses for light, so the cloth colours here
  // have to be the light ones or the preview would not be showing what actually ships.
  dark: {
    bg: [
      [0, "#1B2040"],
      [1, "#171B33"],
    ],
    shadow: "rgba(4,7,20,0.55)",
    rod: [
      [0, "#9F8763"],
      [0.1, "#D8C7A8"],
      [0.2, "#C0A87F"],
      [0.35, "#B79C71"],
      [0.48, "#A78A5F"],
      [0.62, "#94764B"],
      [0.8, "#7E6138"],
      [1, "#6B4F29"],
    ],
    cap: [
      [0, "#A98E67"],
      [0.4, "#8E7247"],
      [1, "#63481F"],
    ],
    ...CLOTH,
  },
  tinted: {
    bg: null,
    shadow: "rgba(0,0,0,0)",
    cloth: [
      [0, ...w(0.97)],
      [0.05, ...w(0.88)],
      [0.13, ...w(0.8)],
      [0.19, ...w(1)],
      [0.28, ...w(0.74)],
      [0.4, ...w(0.66)],
      [0.55, ...w(0.58)],
      [0.72, ...w(0.58)],
      [0.9, ...w(0.64)],
      [1, ...w(0.74)],
    ],
    sheen: [
      [0, ...w(0)],
      [0.34, ...w(0.3)],
      [0.52, ...w(0.36)],
      [1, ...w(0)],
    ],
    // No darkening pass in tinted — alpha only goes one way over a transparent layer, so
    // the down-the-panel variation is carried entirely by the hem glow.
    shade: [
      [0, ...w(0)],
      [1, ...w(0)],
    ],
    glow: [
      [0, ...w(0)],
      [0.6, ...w(0)],
      [0.87, ...w(0.16)],
      [1, ...w(0.3)],
    ],
    rim: [
      [0, ...w(0.7)],
      [0.45, ...w(0.88)],
      [1, ...w(1)],
    ],
    mouth: [
      [0, ...w(0.82)],
      [0.5, ...w(0.66)],
      [1, ...w(0.5)],
    ],
    deep: [
      [0, "#000000", 0.18],
      [0.5, "#000000", 0],
    ],
    loopSide: [
      [0, "#000000", 0.12],
      [0.2, "#000000", 0],
      [0.8, "#000000", 0],
      [1, "#000000", 0.14],
    ],
    mouthRim: "#FFFFFF",
    crease: [
      [0, ...w(0.85)],
      [1, ...w(0)],
    ],
    loop: [
      [0, ...w(0.92)],
      [0.12, ...w(1)],
      [0.35, ...w(0.94)],
      [0.55, ...w(0.78)],
      [0.72, ...w(0.68)],
      [0.88, ...w(0.8)],
      [1, ...w(0.96)],
    ],
    loopShadow: "rgba(0,0,0,0.22)",
    rod: [
      [0, ...w(0.5)],
      [0.1, ...w(0.88)],
      [0.2, ...w(0.74)],
      [0.35, ...w(0.68)],
      [0.48, ...w(0.6)],
      [0.62, ...w(0.52)],
      [0.8, ...w(0.44)],
      [1, ...w(0.38)],
    ],
    cap: [
      [0, ...w(0.56)],
      [0.4, ...w(0.46)],
      [1, ...w(0.34)],
    ],
  },
};

// --- layers -------------------------------------------------------------------------------
// Each is a complete standalone SVG: Icon Composer wants one file per layer so it can give
// each its own shadow and specular pass.
// CoreSVG ignores rgba() inside stop-color, so every stop carries its alpha separately.
const stops = (list) =>
  list
    .map(
      ([o, c, a = 1]) =>
        `<stop offset="${o}" stop-color="${c}"${a === 1 ? "" : ` stop-opacity="${a}"`}/>`,
    )
    .join("");
// Gradients are in objectBoundingBox units so one definition shades every panel, whatever
// its silhouette: x runs rim-to-rim across a panel, y runs rod-to-hem down it.
const linear = (id, list, [x1, y1, x2, y2]) =>
  `    <linearGradient id="${id}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}">${stops(list)}</linearGradient>`;
const across = (id, list) => linear(id, list, [0, 0, 1, 0]);
const down = (id, list) => linear(id, list, [0, 0, 0, 1]);

const svg = (defs, body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
${defs.join("\n")}
  </defs>
${body}
</svg>\n`;

// --- rod: a turned wooden dowel, its highlight stripe a third of the way down, with caps
// that overhang the outer loops at both ends.
const ROD_DEFS = (c) => [
  down("rod", c.rod),
  down("rodcap", c.cap),
  down("rodgloss", [
    [0, "#FFFFFF", 0],
    [0.35, "#FFFFFF", 0.55],
    [0.7, "#FFFFFF", 0],
  ]),
];
const rodBody = () => {
  const h = ROD.y1 - ROD.y0;
  const cap = 15;
  return `  <g>
    <rect x="${ROD.x0}" y="${ROD.y0}" width="${ROD.x1 - ROD.x0}" height="${h}" rx="${ROD.r}" fill="url(#rod)"/>
    <ellipse cx="${ROD.x0 + cap}" cy="${ROD.y0 + h / 2}" rx="${cap}" ry="${h / 2}" fill="url(#rodcap)"/>
    <ellipse cx="${ROD.x1 - cap}" cy="${ROD.y0 + h / 2}" rx="${cap}" ry="${h / 2}" fill="url(#rodcap)"/>
    <rect x="${ROD.x0 + 26}" y="${ROD.y0 + 5}" width="${ROD.x1 - ROD.x0 - 52}" height="14" rx="7" fill="url(#rodgloss)"/>
  </g>`;
};
const rod = (c) => svg(ROD_DEFS(c), rodBody());

// --- shadow: what the hanging cloth throws onto the wall behind it. Icon Composer gives
// every group its own shadow, but the flat composites (docs previews, the splash image and
// the Mac .icns) have no such help, so the drawing carries one of its own.
const SHADOW_DEFS = () => [
  `    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="17"/></filter>`,
];
const shadowBody = (c) => `  <g filter="url(#soft)" fill="${c.shadow}" transform="translate(7 19)">
    <rect x="${ROD.x0}" y="${ROD.y0}" width="${ROD.x1 - ROD.x0}" height="${ROD.y1 - ROD.y0}" rx="${ROD.r}"/>
${[0, 1]
  .map((i) => `    <path d="${cloth(TOPS[i], hemOf(i))}"/>`)
  .join("\n")}
    <path d="${curlBody()}"/>
  </g>`;
const shadow = (c) => svg(SHADOW_DEFS(), shadowBody(c));

// --- panels: the cloth itself. Each silhouette is painted four times — body, the warm
// pass that saturates its middle, the glow under the hem, then the thin bright rim.
const PANEL_DEFS = (c) => [
  ...SPAN.map(
    ([x0, x1], i) =>
      `    <linearGradient id="cloth${i}" gradientUnits="userSpaceOnUse" x1="${x0}" y1="0" x2="${x1}" y2="0">${stops(c.cloth)}</linearGradient>`,
  ),
  down("shade", c.shade),
  across("sheen", c.sheen),
  down("glow", c.glow),
  down("rim", c.rim),
  linear("mouth", c.mouth, [0.08, 0, 0.95, 0.88]),
  linear("crease", c.crease, [0, 1, 0.45, 0]),
  linear("deep", c.deep, [0.05, 0.05, 0.8, 0.95]),
  `    <clipPath id="roll"><path d="${curlBody()}"/></clipPath>`,
];
const shadeCloth = (d, i) =>
  [
    `    <path d="${d}" fill="url(#cloth${i})"/>`,
    `    <path d="${d}" fill="url(#shade)"/>`,
    `    <path d="${d}" fill="url(#glow)"/>`,
    i === 2
      ? `    <g clip-path="url(#roll)"><path d="${sheenBand(i)}" fill="url(#sheen)"/></g>`
      : `    <path d="${sheenBand(i)}" fill="url(#sheen)"/>`,
    `    <path d="${d}" fill="none" stroke="url(#rim)" stroke-width="5"/>`,
  ].join("\n");
const panelsBody = (c) => `  <g>
${[0, 1].map((i) => shadeCloth(cloth(TOPS[i], hemOf(i)), i)).join("\n")}
${shadeCloth(curlBody(), 2)}
    <path d="${curlCrease()}" fill="none" stroke="url(#crease)" stroke-width="7" stroke-linecap="round"/>
    <path d="${curlMouth()}" fill="url(#mouth)"/>
    <path d="${curlMouth()}" fill="url(#deep)"/>
    <path d="${curlMouth()}" fill="none" stroke="${c.mouthRim}" stroke-width="6" stroke-linejoin="round"/>
  </g>`;
const panels = (c) => svg(PANEL_DEFS(c), panelsBody(c));

// --- loops: short tabs wrapping over the rod, each throwing a soft bar of shadow onto the
// cloth below it.
const LOOP_DEFS = (c) => [
  down("loop", c.loop),
  across("loopside", c.loopSide),
  `    <filter id="loopblur" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="7"/></filter>`,
];
const loopsBody = (c) => {
  const h = LOOP.y1 - LOOP.y0;
  const each = (f) => [0, 1, 2].map((i) => f(loopCx(i) - LOOP.w / 2)).join("\n");
  return `  <g>
    <g filter="url(#loopblur)" fill="${c.loopShadow}">
${each((x) => `      <rect x="${x - 2}" y="${LOOP.y1 - 22}" width="${LOOP.w + 4}" height="30" rx="14"/>`)}
    </g>
${each((x) => `    <rect x="${x}" y="${LOOP.y0}" width="${LOOP.w}" height="${h}" rx="${LOOP.r}" fill="url(#loop)"/>`)}
${each((x) => `    <rect x="${x}" y="${LOOP.y0}" width="${LOOP.w}" height="${h}" rx="${LOOP.r}" fill="url(#loopside)"/>`)}
  </g>`;
};
const loops = (c) => svg(LOOP_DEFS(c), loopsBody(c));

// Back to front: SVG paints in document order, so this is the icon.json group list
// reversed. The shadow is behind everything, the rod hangs behind the cloth, and the loops
// sit in front of both.
const composite = (c, backdrop, wrap = (art) => art) =>
  svg(
    [
      ...SHADOW_DEFS(),
      ...ROD_DEFS(c),
      ...PANEL_DEFS(c),
      ...LOOP_DEFS(c),
      ...(c.bg ? [down("bg", c.bg)] : []),
    ],
    backdrop +
      wrap([shadowBody(c), rodBody(), panelsBody(c), loopsBody(c)].join("\n")),
  );

const write = (p, s) => (mkdirSync(dirname(p), { recursive: true }), writeFileSync(p, s));

// Light and dark share the cloth — only the rod, the background and the shadow change — so
// there is no -dark cloth. (PALETTES.dark spreads the light cloth back in, so the previews
// agree with that.)
write(join(assets, "shadow.svg"), shadow(PALETTES.light));
write(join(assets, "shadow-dark.svg"), shadow(PALETTES.dark));
write(join(assets, "shadow-tinted.svg"), shadow(PALETTES.tinted));
write(join(assets, "rod.svg"), rod(PALETTES.light));
write(join(assets, "rod-dark.svg"), rod(PALETTES.dark));
write(join(assets, "rod-tinted.svg"), rod(PALETTES.tinted));
write(join(assets, "loops.svg"), loops(PALETTES.light));
write(join(assets, "loops-tinted.svg"), loops(PALETTES.tinted));
write(join(assets, "panels.svg"), panels(PALETTES.light));
write(join(assets, "panels-tinted.svg"), panels(PALETTES.tinted));

// The composites are the flat previews: no glass, no specular, just the artwork on its
// background, which is all a docs screenshot or the splash image needs. Tinted has no
// background of its own — the system supplies one — so the preview puts it on near-black
// to make a white-on-nothing layer stack visible at all.
const out = process.argv[2];
if (out) {
  for (const [name, c] of Object.entries(PALETTES)) {
    const fill = c.bg ? "url(#bg)" : "#101014";
    write(
      join(out, `icon-${name}.svg`),
      composite(c, `  <rect width="1024" height="1024" fill="${fill}"/>\n`),
    );
  }
  // The Mac build has no asset catalog to compile the .icon into, so its .icns carries the
  // rounded shape baked in: the 824pt body on the 1024pt canvas that macOS icons use.
  const inset = 100;
  const k = (1024 - inset * 2) / 1024;
  write(
    join(out, "icon-macos.svg"),
    composite(
      PALETTES.light,
      `  <rect x="${inset}" y="${inset}" width="${1024 - inset * 2}" height="${1024 - inset * 2}" rx="185" fill="url(#bg)"/>\n`,
      (art) => `  <g transform="translate(${inset} ${inset}) scale(${k})">\n${art}\n  </g>`,
    ),
  );
}
