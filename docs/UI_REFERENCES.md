# 小家 0.2 · design and feature decisions

## References inspected

- Anthropic: https://www.anthropic.com/news/claude-design-anthropic-labs
  The article describes consistent design systems, realistic prototypes and refinement. It does not prescribe a universal Claude Design visual style. Our warm neutral home, serif headline, restrained cards and iOS chat layout are original design choices.
- Douyin creator post: https://www.douyin.com/video/7664077136835557541
  Search indexes identify a creator's self-built companion frontend / 20-feature tutorial. Full video could not be retrieved; its unseen individual features are not assumed.
- Douyin voice-bar post: https://www.douyin.com/video/7678025715619172593
  Search indexes explicitly mention a voice bar. Full video was not available, so we implement an original native voice control.
- LandricSpace author README: https://github.com/LuQianClaude/LandricSpace
  Describes a shared home with calendar, mood, notes, photos, messages, moments and music. Borrowed the broad idea of a personal daily space, not source code, assets or branding.
- Xiaohongshu searches for Claude 人机恋 前端 UI did not expose enough accessible primary content for reliable feature attribution.

## Shipped

- Native iMessage-inspired chat: blue outgoing / system gray incoming, grouped bubble tails, inline contact header, rounded composer, adaptive dark mode and Dynamic Type.
- Quote replies: explicit quoted context sent through the existing text API, with a separate visual quote block. No claim of server-side reply IDs.
- Long-press copy, share and local keepsakes, with a distinct “我收藏的” section.
- Search of the latest history returned by the existing backend, not full-history search.
- Persistent drafts, safe queued sends/retries, no fake read receipts or invented historic timestamps.
- Scroll stays in place while reading old messages; a new-message button returns to the latest message.
- Actual audio duration/progress and protected local persistence of voice replies received by this client. No additional TTS calls or paid service.
- User-selected local avatar/wallpaper through the system photo picker; image copies are resized and protected on disk.
- Editable relationship caption, optional anniversary, local daily mood journal and local little notes. Sharing a note/mood places text in the composer for the user to send.
- Existing shared memory, diary and bot favorites remain on the existing backend.

## Future work requiring separate capabilities

True voice calls need real-time audio transport and ASR; photo messages need a backend image endpoint; offline push needs APNs/signing support; widgets require an extension. The interface does not show nonfunctional call/record/image-send buttons or simulate those features. Shared albums, music and automatic mood inference are not implemented in this release.

## Validation

Release IPA compiles with Xcode on macOS. The same workflow separately compiles Debug for an iOS simulator, runs UI tests for search, quote cancellation and local-favorite persistence, launches synthetic preview messages with a DEBUG-only argument, and captures light/dark chat and home screenshots. Release builds contain no preview branch and no account credentials.

## 0.3 user-directed revision

The user requested glass, custom wallpaper, individual sentence bubbles, Return sending and edge back navigation. This replaces the 0.2 iMessage imitation with original translucent rounded cards and a floating dock. Apple native Liquid Glass requires iOS 26; older builds/systems use ultra-thin material with highlights. Photo wallpaper now appears on home and chat with optional blur/shade. Assistant text splits for display only; original history and voice IDs are preserved. Quote/copy/manual favorite act on the selected sentence, while search anchors still refer to original messages. The composer handles a typed Return separately from pasted paragraphs and IME marked text. NavigationStack preserves the previous root screen; native left-edge rightward pop and right-edge leftward back are supported.

Official technical references:
- https://developer.apple.com/documentation/swiftui/glass
- https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- https://developer.apple.com/documentation/swiftui/understanding-the-navigation-stack

## 0.4 performance, shared reading and device privacy

References inspected (feature inspiration only; no third-party source, assets or prompts copied):
- https://github.com/zzyyksl/reading-nook — local reading progress, chosen-text notes and separate reader/AI annotations. This release implements a native local bookshelf, progress, bookmarks and user notes. AI answers use the existing chat, not automatic in-book annotations. Its subscription-based file-writing agent is NOT assumed to exist in our API-based bot, so that cost model is not advertised.
- https://github.com/TricksterFlare/tavern-study — separate setting shelf, shared reading corner and RP desk. Do not conflate importing lore assets with installing a whole autonomous agent or all SillyTavern extensions. No code copied; inspected README currently says AGPL-3.0.
- https://docs.sillytavern.app/usage/core-concepts/worldinfo/ — world info dynamically supplies prompt context; it is not a scheduler or OS tool permission.
- https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate — background launch timing is not guaranteed. Independent activities should run on an authenticated server queue with budgets, audit records and explicit tool scopes, not an always-running phone timer.
- https://developer.apple.com/documentation/uikit/uidevice/batterylevel — unknown levels must not be invented. Device state is opt-in and foreground-only; only deliberate chat sends share a timestamped snapshot.
- https://developer.apple.com/documentation/healthkit/setting-up-healthkit and https://developer.apple.com/help/account/reference/supported-capabilities-ios — HealthKit needs capability/signing support and data-type consent. No HealthKit entitlement or prompt is shipped before verifying compatibility with the user's free signing workflow.

Performance changes: incremental message cache, no unchanged-history replacement, no file-system checks during every bubble render, separate audio progress observation, initial bottom scroll anchor rather than an entry-time jump, no per-bubble live blur/shadow, radial backgrounds instead of giant blurred ellipses, and removal of duplicate home wallpaper layers. These remove identified hot paths; real-device frame rate still needs the user's installation check.

Import and PDF text extraction run off the main actor. Books are protected local files, the index stores only progress/note metadata, and sharing explicitly previews a bounded excerpt. EPUB, DRM books, OCR, automatic server reading, in-book AI replies and health access are not implemented. Existing drafts are appended to, never overwritten. No private book, device data or credentials are committed to the public repository.
