# Changelog

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