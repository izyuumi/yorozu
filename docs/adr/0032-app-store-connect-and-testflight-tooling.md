# 0032. App Store Connect and TestFlight tooling

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Several scripts talk to the App Store Connect API. Some changes reach every tester or go live with a release, so they must never run from CI by accident, must be idempotent, and must never leak the API key.

## Decision

- External TestFlight kill switch (`scripts/external_testflight.sh`):
  - A step that would give a build to an external TestFlight group or submit it to Beta App Review runs the switch first and goes on only if it exits 0. It exits 0 only when the repository variable `YOROZU_EXTERNAL_TESTFLIGHT`, passed into the job's environment, is exactly `true`; unset, empty, `false`, `TRUE` or anything else exits 1.
  - Builds reach the internal group without it. `release-ios.yml` leaves the variable unset, so internal group only. `upload_ios.sh` gives no build to an external group or to Beta App Review.
  - `--audit` exits 1 if a workflow or script names an App Store Connect group or Beta App Review call without running the switch; `checks.yml` runs it in `release-guards`.
- What to Test (`upload_ios.sh set_whats_new`): in every locale with a folder in `apps/ios/metadata/testflight`, the PRs merged since the last stable tag (`release_notes.sh --what-to-test`). A missing locale is created; an existing one is set only while empty or still holding this script's text for this build (its first line is one of the intros), so text someone wrote by hand stays. Locales without a folder are left alone. It is the build's own text, so it reaches only the groups that get the build: TestFlight's internal group.
- Hand-run scripts, never in CI:
  - `testflight_metadata.sh`: the beta app description in every locale with a folder. The beta app localizations belong to the app, so every tester sees them, the external Public group's too.
  - `app_store_metadata.sh`: the App Store listing; it edits what the App Store shows once the version is released. It edits only the iOS version still being prepared and its app info; it never creates, submits or releases a version.
  - `app_store_submit.sh <version> <build>`: submits to App Store review; a submitted version is released by Apple once approved, by its release type.
  - `app_store_media.sh`: screenshots and creative art; the media goes live with the version.
- Shared behaviour of those scripts:
  - Without `--apply` (or a write flag) they read App Store Connect and print the plan; they write nothing.
  - A locale App Store Connect lacks is created, and an empty field is set, from the locale folder's files. Fields kept only in App Store Connect are copied from en-US where empty: the feedback email, marketing URL and privacy policy URL for TestFlight; the marketing, support and privacy policy URLs for the App Store. Text that differs from its file is kept and reported, since someone may have written it by hand. Locales without a folder are left alone.
  - Running twice changes nothing the second time.
  - Exit codes: 0 done or nothing blocks the plan, 64 bad arguments, 65 blocked (reason printed), 70 App Store Connect refused a write (or, for media, failed to process an upload). The key handling exits 1 without a key.
- `app_store_metadata.sh --check` checks the files against App Store Connect's limits offline, with no key. Limits count characters; keywords count bytes, as App Store Connect counts them. Description and What's New are at most 4,000 characters and are kept within 4,000 bytes as well.
- `app_store_submit.sh`:
  - `--create` creates the version if missing, else reuses it, and sets its release type; `--attach` attaches the build only if it is VALID, not expired and was uploaded for that version; `--submit` creates or reuses the open review submission, adds the version once and submits it.
  - The release type defaults to that of the newest version on sale. It also reports the content rights declaration and the build's export compliance against `ITSAppUsesNonExemptEncryption` in `apps/ios/Project.swift`.
  - Everything is read first, and every step reads the state again before it writes; nothing is written if anything blocks.
- `app_store_media.sh`:
  - Sources per locale: `screenshots/<device>/*.png|*.jpg` in file-name order, where `<device>` names the placement group (`iphone-6.9` IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE, `iphone-6.5` IPHONE_FACE_ID_LARGE_PROFILE, `iphone-6.3` IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE, `ipad-13` IPAD_13_PROFILE, `iphone-duo` IPHONE_DUO_PROFILE); `creative/header.png` (PRODUCT_PAGE_HEADER_ASSET) and `creative/search.png` (APP_STORE_SEARCH_RESULTS_ASSET), both DEFAULT_PROFILE. A localization without its own header or search art gets `FALLBACK_HEADER` or `FALLBACK_SEARCH`.
  - It works on one iOS version, the one being prepared or `--version`, and refuses (65) one App Store Connect no longer lets you edit.
  - Every file is checked first against the image specs App Store Connect lists (`GET /v1/appAssetLibraryRefData`): exact pixel size, alpha channel (via sips), file type and size, and the count limit per group. `--apply` runs the plan first and writes nothing unless it passes.
  - Upload: each file the library lacks is reserved, its bytes PUT, committed and polled until processed. The library has no checksum field, so the reference name carries the file's SHA-256 (`sha256:<16 hex>`); a file whose checksum is in the library is not uploaded again, nor is one uploaded some other way with the same byte count and pixel size.
  - Place: each image not yet on the localization gets a placement. A header or search art already placed with another image is kept and reported: there is room for one.
  - Order: the repo's screenshots first, in file-name order, then the ones already there.
  - A localization with no screenshots for a device shows en-US's; once it has its own it shows only those. The plan says where that happens, and `--carry-en-us` also places en-US's other screenshots after the localization's own, as far as the limit allows. Nothing is deleted.
- Credentials (`scripts/asc_lib.sh`, sourced by `upload_ios.sh` and `testflight_metadata.sh`): needs `ASC_KEY_ID` and `ASC_ISSUER_ID`; the key is `ASC_KEY_PATH` or `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`. The key and the signed token go only to openssl and curl's standard input, never into arguments or output. `asc_send` prints the body on a 2xx; otherwise it prints App Store Connect's errors (status, code, title, detail) to stderr and returns 22, like `curl -f`; a transport failure returns curl's own exit code. The response body never holds the key or the token.

## Consequences

- Nothing reaches external testers or the App Store without a deliberate human step.

## Where in the code

- `scripts/external_testflight.sh`
- `scripts/upload_ios.sh` — `set_whats_new()`, kill switch call
- `scripts/testflight_metadata.sh`
- `scripts/app_store_metadata.sh` — `check()`
- `scripts/app_store_submit.sh`
- `scripts/app_store_media.sh` — `image()`
- `scripts/asc_lib.sh` — `jwt()`, `asc_send()`
- `.github/workflows/release-ios.yml` — `YOROZU_EXTERNAL_TESTFLIGHT`
- `.github/workflows/checks.yml` — `release-guards`
