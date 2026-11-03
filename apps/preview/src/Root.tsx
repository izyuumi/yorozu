import { Composition } from "remotion";
import { AppPreview, type Props } from "./AppPreview";

// 886x1920 serves the 6.9" and 6.5" iPhone slots; 870 frames at 30 fps is 29.0 s (App Store Connect allows 15–30 s).
export const Root = () => (
  <Composition
    id="AppPreview"
    component={AppPreview}
    width={886}
    height={1920}
    fps={30}
    durationInFrames={870}
    defaultProps={{ locale: "en-US" } satisfies Props}
  />
);
