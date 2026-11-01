# Changelog

## 0.12.0

### Features

- **wire:** send the unversioned wire format to plugins that list unversioned-wire (#651)
- **plugin:** list unversioned-wire and test both frame formats (#532 wire step 1) (#650)
- pair with the Gateway on this Mac (#532) (#649)
- offline pairing over the direct path (#532 step 5) (#647)
- Local Network explainer, denied path, Connection row and hourly Bonjour tag (#532 step 4, PR B) (#645)
- direct path hints, candidate filtering, Bonjour and pre-warm (#532 step 4, PR A) (#644)
- direct listener and loopback transport behind the direct capability (#642)
- **ios:** show the demo in all nine languages (#641)
- **ios:** show automation schedules in the app's language (#640)
- **relay:** host push {device, token} for directly connected devices (#634)
- counts-only relay pushes for the Live Activity (#629)
- **ios:** one Live Activity for turns, voice and approvals (#624)
- resumable attachment uploads and downloads (capability resume) (#628)
- **web:** show a Yorozu chat on iPhone in the home hero (#627)
- **ios:** choose a voice input model and keep a voice dictionary (#622)
- **ios:** Talk and Ask launchers for the Lock Screen (#623)
- **ios:** widgets, controls and a device-local Live Activity (#621)
- **web:** simplify the home page and add a copyable AI agent setup prompt (#620)
- serve the help MCP server from the website at yorozu.yumi.to/mcp (#619)
- add a read-only help MCP server for AI agents (#617)
- show the mic in the send slot while the composer is empty (#613)

### Fixes

- **app:** retry an attachment open once if the stored-names move removed the old file (#653)
- **app:** migrate pairing-v3 and the -v3 data folders with verified, crash-safe moves (#652)
- **ios:** clear the pairing code when pairing is cancelled (#648)
- label a wired LAN route "Direct (local network)" and skip loopback when the host is on another machine (#532) (#646)
- race the last winner first, give direct a head start only after it won, and re-race at once (#643)
- **relay:** host push refreshes the device's last-seen time (#639)
- **mac:** expose the composer as one Message field (#638)
- tolerate unknown types, fields and values in every reader (#636)
- **ios:** re-decode an LFM3-Audio window that stops before its end (#635)
- **ios:** cap seam de-duplication by the speech in the overlap (#633)
- **ios:** transcribe long LFM3-Audio clips in windows (#632)
- type the frame header bytes in decodeFrame (#630)
- **ios:** show the sidebar on a cold launch (#626)
- **ios:** keep only the Ask Lock Screen launcher, showing the Yorozu mark alone (#625)
- let the 128 MB attachment default apply (#618)
- **ios:** title in-app reply notices with the conversation's title (#616)
- keep the mic beside send while the composer has content (#615)
- **ios:** drop the chat-bubble icon from in-app reply notices (#614)
- use continuous rounded corners for in-app notices (#612)
- drop animations on keyboard and high-frequency actions (#609)

### Performance

- **ios:** keep the times swipe from rebuilding the whole chat (#637)

## 0.11.0

### Features

- **web:** auto-detect the visitor's language and translate the website into eight languages (#603)
- **web:** refresh the website for 0.10 with the current icon and app colors (#601)
- **ios:** script to create the App Store version, attach the build and submit for review (#600)
- **ios:** App Store listing in every app language (#598)

### Fixes

- **mac:** fit the add-device sheet without scrolling and enlarge the QR code on click (#605)
- **ios:** say plainly when the voice model asset pack isn't available yet (#604)
- **ios:** use よろず Yorozu as the Japanese App Store name; show App Store Connect errors (#602)

## 0.10.0

### Features

- **client:** focus the composer when opening a conversation on the Mac (#597)
- About settings with Copy Diagnostics (#595)
- attachments up to 128 MB by default (#583)

### Fixes

- **ci:** What to Test and beta description in every app language (#596)
- **ci:** wait until App Store Connect lists each iOS upload so the next can't reuse its build (#593)
- **ios:** show each feature tip once, at most one a day (#589)
- **ci:** restore one v&lt;version&gt;-beta release per version (#588)
- **client:** tool-call count uses plural variations instead of inflection (#587)
- **ci:** make promote.yml valid YAML (#586)
- **mac:** give reply text and composer SwiftUI accessibility labels (#585)
- **ci:** approve the release PR's checks instead of dispatching them (#582)
- **ci:** keep beta tags; number the next beta from them (#580)