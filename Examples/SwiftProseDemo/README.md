# SwiftProseDemo

End-to-end SwiftUI demo + UI test target for SwiftProse. References the local SPM package at `../..`.

## Run

Open `SwiftProseDemo.xcodeproj` in Xcode, or:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
    -scheme SwiftProseDemo \
    -destination 'platform=macOS'

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project Examples/SwiftProseDemo/SwiftProseDemo.xcodeproj \
    -scheme SwiftProseDemo \
    -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Targets

- `SwiftProseDemo` — multi-platform App (iOS 26 / macOS 26).
- `SwiftProseDemoUITests` — XCUITest bundle covering editor typing, toolbar visibility, and PM JSON load/export round-trip.
