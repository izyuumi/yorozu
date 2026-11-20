import { Composition } from "remotion";
import { AppPreview, type Props } from "./AppPreview";

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
