# Provider mark assets

Yorozu uses these marks only as small identifiers for the agent selected for a thread. They are
not part of Yorozu's name, app icon, or product branding. The files below are stored without path,
color, aspect-ratio, or view-box edits and are rendered with original colors.

## Claude

- Asset: `ClaudeMark.imageset/ClaudeMark.svg`
- Source: `.github/logo.svg` from Anthropic's official `@anthropic-ai/sdk` package, version
  `0.125.0`. Anthropic's official SDK README displays it beside “Claude SDK for TypeScript.”
- Upstream: <https://github.com/anthropics/anthropic-sdk-typescript/blob/main/.github/logo.svg>
- SHA-256: `b150888bc7257af83e3b85d3c2be4294f88986026f8168f6c12fc1fde6697350`
- License: the package is MIT licensed; see `THIRD_PARTY_NOTICES.md`.

## Codex

OpenAI's Codex page, official `openai/codex` repository, and official brand download did not
publish a separate distributable Codex product icon when inspected on 2026-09-21. Yorozu therefore
uses the official OpenAI Blossom paired with visible `Codex` text, rather than inventing a mark.

- Assets: `OpenAIBlossom.imageset/OpenAIBlossom-Black.svg` and
  `OpenAIBlossom.imageset/OpenAIBlossom-White.svg`
- Source: `openai-logos.zip`, linked by OpenAI's official design guidelines at
  <https://openai.com/brand/>. Original archive filenames are
  `OAI_OpenAI-Blossom_Black.svg` and `OAI_OpenAI-Blossom_White.svg`.
- Archive URL: <https://cdn.openai.com/brand/openai-logos.zip>
- Archive SHA-256: `c54e85ab5884228f89f0230dd8effa8d588cad78166fe954135f4afa553222db`
- Black SVG SHA-256: `75c1e9fffa5e8c437bec1d67197a73992bca45d166c6ff23215185dea8fae92a`
- White SVG SHA-256: `01d158767c4eec0e47bd617e67759c33da0accd1438be1a8d29dfdb99ce87285`
- Usage: black in light appearance and white in dark appearance, preserving OpenAI's supplied
  clear space. See <https://openai.com/brand/#usage-terms>.
