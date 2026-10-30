# TestFlight text

One folder per App Store Connect locale, for every language the app ships in (`apps/ios/Resources/*.xcstrings`):
`en-US` (the primary locale), `ja`, `zh-Hans`, `zh-Hant`, `ko`, `es-ES`, `fr-FR`, `de-DE` and `pt-BR`. As with the
interface, the text past English and Japanese is machine-translated.

- `what_to_test.txt`: the labels around each build's What to Test (`scripts/release_notes.sh --what-to-test`).
  `intro` is the first line, `note` an optional second line, `feat`, `fix` and `perf` the section headings (with their colon), and `more`
  the line that ends a list cut at 4,000 bytes. `{version}`, `{build}` and `{count}` are filled in. The PR titles
  stay in English: CI has no translation, and a title is what its PR says.
- `description.txt`: the beta app description TestFlight shows testers (`scripts/testflight_metadata.sh`).

Adding a language means adding its folder with both files.
