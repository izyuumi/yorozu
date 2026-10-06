/** DEVELOPMENT fresh-profile boundary; never adopts or replays historical work. */
export const NATIVE_PINS = Object.freeze({
  "derivedCommit": "f04797ef4d24f3da0f9df74acd58ab773ab5f11e",
  "fullUpstreamDiffSha256": "601c2eea193de989977a122a98bda8653910848092f7c4937195e40bf63ebc4e",
  "buildInfoSha256": "38390412b3f1a8109e5e63c30ba9686076571539efa8df3010d4c0d45a55514d",
  "entrySha256": "c7f8d626f2751ee75995ca991b594fb41a21afe0d053e81883a8f85c2eede68e",
  "protocolSchemaSha256": "e5dad9efc6acfb59124d1c9872541b811abc56956d3d11abea7f2c37866aed4a",
  "lockfileSha256": "c717cc8ed7331b2b4787ed4cbe80d46d3d733de69e3dc9dd7f1d49e6b4942802",
  "node": {
    "binarySha256": "56d28b39a8048f0cd1af7ad7e09f6cbe1c04439b6dfeb6c8d9090c082af60861",
    "version": "26.10.0"
  },
  "artifactManifestSha256": "9db6607638d61a5688e94981d5cf66bdc8ef68d64ded824666f32bb2ae68684f",
  "runtimeArchiveSha256": "a023bf8fd6ee63c8fe82c42c64fb6598eaeb63746c89513230509694cf5b557b"
});
export const INPUT_CONTRACT = 'literal-v1';
export const RUNTIME_IDENTITY = JSON.stringify(NATIVE_PINS);
export function validateLiteralOwner(previous, owner) {
  if (Object.keys(previous).length !== Object.keys(owner).length ||
      Object.entries(owner).some(([key, value]) => previous[key] !== value)) {
    throw new Error('profile migration required: preserve old profile stopped/snapshot-only; use a fresh profile, never replay unknown operations');
  }
}
