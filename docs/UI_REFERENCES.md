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
