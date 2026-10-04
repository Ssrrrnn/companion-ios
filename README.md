# 小家 · Personal iOS companion

A generic SwiftUI client for a personal companion service. iMessage-inspired chat, persistent audio playback, quote replies, search, diaries, favorites and a personal daily space use your own HTTPS backend. Credentials are entered in Settings and the connection token is stored in the iOS Keychain. This repository and its public releases contain no service credentials.

## AltStore Classic updates

Source URL:

```
https://raw.githubusercontent.com/Ssrrrnn/companion-ios/main/altstore-source.json
```

In AltStore Classic, open Sources, tap +, paste the URL and add it. Open 小家 in this source to install/update using the same Apple account. Keep the existing app when updating. Free-account signing and normal AltServer refresh requirements still apply; this source distributes updates, it does not change signing limits.

## Publishing changes

Push client changes under `ios/` to `main`, or run **Build and publish personal iOS app** manually. On the public repository, GitHub Actions builds an unsigned IPA on macOS and publishes it as a versioned GitHub Release. Only the Linux publication job has repository contents write permission. After upload size verification, it advances `altstore-source.json`. Failed builds never update the source.

Every workflow run/attempt supplies a distinct numeric build number; `ios/project.yml` holds the marketing version. Update `RELEASE_NOTES.txt` with each change. IPA metadata, bundle identifier, version, minimum iOS and privacy permission descriptions are read from the built archive. A source update cannot replace newer client code on main. Older releases remain downloadable.

The IPA is unsigned so AltStore can sign it locally. Do not add personal tokens or backend credentials to the public repository. A signed distribution pipeline needs explicit entitlement inspection before using this publisher.

## Interface and personal space

Version 0.2 adds avatars, wallpaper, bubble colors, adaptive light/dark appearance, anniversary, daily moods and little notes. Manual keepsakes and personal settings remain on the device; diary and bot favorites use the existing server. No additional paid API is used. Search covers the recent history returned by the server.

Every release also compiles the app for an iOS simulator and captures actual light/dark chat and home previews using synthetic DEBUG-only content. Release publication waits for both builds. See [design references](docs/UI_REFERENCES.md).

## Local build on a Mac

Install Xcode and XcodeGen, then run `bash ios/build.sh`. The output is `ios/build/Companion.ipa`. This client requires iOS 18 or later.
