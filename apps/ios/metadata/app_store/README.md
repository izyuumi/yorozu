# App Store listing

One folder per App Store Connect locale, the same languages as `../testflight` and the app's string catalogs. `en-US`
is the listing for 0.9.3 as it stands in App Store Connect; the other languages are machine-translated from it, using
the interface's own words for its features (Pin, Archive, Edit in Chat, Settings).

| File | App Store Connect field | Limit |
| --- | --- | --- |
| `name.txt` | Name | 30 characters |
| `subtitle.txt` | Subtitle | 30 characters |
| `keywords.txt` | Keywords, comma-separated | 100 bytes |
| `promotional_text.txt` | Promotional Text | 170 characters |
| `description.txt` | Description | 4,000 characters |
| `release_notes.txt` | What's New in This Version | 4,000 characters |

`scripts/app_store_metadata.sh --check` checks these limits, offline, and runs in Checks. Without a flag the script
prints what it would change in the iOS version being prepared in App Store Connect; `--apply`, run by hand, makes
those changes. It never creates or submits a version. Update `release_notes.txt` in every locale for each version
before you run it. The URLs come from en-US in App Store Connect and are not kept here.

Adding a language means adding its folder with all six files, here and in `../testflight`.

## Screenshots and art

| Path | What |
| --- | --- |
| `<locale>/screenshots/<device>/` | Screenshots, in file-name order: `iphone-6.9`, `iphone-6.5`, `iphone-6.3`, `ipad-13`, `iphone-duo` |
| `<locale>/creative/header.png` | Product page header, 3840x1646 |
| `<locale>/creative/search.png` | Search results art, 3840x2560 |
| `en-US/creative/header-textless.png` | Header without text, for locales without their own |

A locale without its own header or search art gets `en-US/creative/header-textless.png` and `en-US/creative/search.png`.
`scripts/app_store_media.sh` prints what it would upload, place and order in the iOS version being prepared; `--apply`,
run by hand, does it. PNGs must have no alpha channel and the exact pixel size App Store Connect lists for the group.
Why the art looks the way it does: [ART.md](ART.md).
