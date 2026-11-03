import type { CSSProperties } from "react";
import { AbsoluteFill, Easing, Img, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame } from "remotion";
import icon from "../../ios/Resources/Assets.xcassets/AppIconImage.imageset/icon-1024.png";
import enUS from "./timeline/en-US.json";
import ja from "./timeline/ja.json";

export type Props = { locale: "en-US" | "ja" };
type Timeline = typeof enUS;

const timelines: Record<Props["locale"], Timeline> = { "en-US": enUS, ja };
// The website's text stack (apps/web/public/styles.css --text); Hiragino Sans for Japanese.
const fonts: Record<Props["locale"], string> = {
  "en-US": '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif',
  ja: '-apple-system, BlinkMacSystemFont, "Hiragino Sans", "SF Pro Text", "Helvetica Neue", sans-serif',
};

const frames = (seconds: number) => Math.round(seconds * 30);
const DISSOLVE = frames(0.4);
const ENTER = 10;
const EXIT = 6;
const END = 870;
const MARGIN = 40;

/** Soft ease-out in over `ENTER` frames from `from`, shorter ease-in out over `EXIT` frames before `to`; no exit at the end. */
function presence(frame: number, from: number, to: number): number {
  const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
  const enter = interpolate(frame, [from, from + ENTER], [0, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
  const exit = to >= END ? 1 : interpolate(frame, [to - EXIT, to], [1, 0], { ...clamp, easing: Easing.in(Easing.cubic) });
  return Math.min(enter, exit);
}

/** One take, full-bleed at normal speed, trimmed by its in-point; every take after the first dissolves in. */
function Take({ src, inPoint, dissolve }: { src: string; inPoint: number; dissolve: boolean }) {
  const frame = useCurrentFrame();
  const opacity = dissolve ? interpolate(frame, [0, DISSOLVE], [0, 1], { extrapolateRight: "clamp" }) : 1;
  return (
    <AbsoluteFill style={{ opacity }}>
      <OffthreadVideo src={src} trimBefore={inPoint} muted style={{ width: "100%", height: "100%", objectFit: "cover" }} />
    </AbsoluteFill>
  );
}

const card: CSSProperties = {
  background: "rgba(255, 255, 255, 0.88)",
  backdropFilter: "blur(24px) saturate(1.4)",
  boxShadow: "0 12px 40px rgba(0, 0, 0, 0.14)",
  color: "#000000",
};

export const AppPreview = ({ locale }: Props) => {
  const frame = useCurrentFrame();
  const timeline = timelines[locale];
  const captions = timeline.captions.map((c) => ({ ...c, from: frames(c.from), to: frames(c.to) }));
  // The band stays up across back-to-back captions and leaves only at the dissolves.
  const runs = captions.reduce<{ from: number; to: number }[]>((all, c) => {
    const last = all.at(-1);
    if (last && last.to === c.from) last.to = c.to;
    else all.push({ from: c.from, to: c.to });
    return all;
  }, []);
  const run = runs.find((r) => frame >= r.from && frame < r.to);
  const caption = captions.find((c) => frame >= c.from && frame < c.to);
  const disclosure = frames(timeline.disclosure.from);
  const end = frames(timeline.end.from);
  const font: CSSProperties = { fontFamily: fonts[locale], letterSpacing: locale === "ja" ? 0 : "-0.01em" };

  return (
    <AbsoluteFill style={{ backgroundColor: "#000000" }}>
      {timeline.scenes.map((s, index) => (
        <Sequence key={s.scene} name={s.scene} from={frames(s.from)} durationInFrames={frames(s.to) - frames(s.from)}>
          <Take src={staticFile(`${locale}/${s.scene}.mp4`)} inPoint={frames(s.inPoint)} dissolve={index > 0} />
        </Sequence>
      ))}
      {run && (
        <div
          style={{
            ...card,
            ...font,
            position: "absolute",
            top: 132,
            left: MARGIN,
            right: MARGIN,
            borderRadius: 40,
            padding: "28px 32px",
            minHeight: 204,
            boxSizing: "border-box",
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            alignItems: "center",
            gap: 14,
            textAlign: "center",
            opacity: presence(frame, run.from, run.to),
          }}
        >
          {caption && (
            <div style={{ fontSize: 64, fontWeight: 700, lineHeight: 1.15, textWrap: "balance", opacity: presence(frame, caption.from, caption.to) }}>
              {caption.text}
            </div>
          )}
          {frame >= disclosure && (
            <div style={{ fontSize: 34, fontWeight: 600, lineHeight: 1.2, color: "#3C3C43" }}>{timeline.disclosure.text}</div>
          )}
        </div>
      )}
      {frame >= end && (
        <div
          style={{
            ...card,
            ...font,
            position: "absolute",
            top: 420,
            left: "50%",
            transform: "translateX(-50%)",
            borderRadius: 48,
            padding: "36px 56px",
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: 20,
            opacity: presence(frame, end, END),
          }}
        >
          <Img src={icon} style={{ width: 168, height: 168, borderRadius: 38 }} />
          <div style={{ fontSize: 56, fontWeight: 700, whiteSpace: "nowrap" }}>{timeline.end.name}</div>
        </div>
      )}
    </AbsoluteFill>
  );
};
