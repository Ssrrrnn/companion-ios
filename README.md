# Morrow · Personal iOS companion

A generic SwiftUI client for a personal companion service. Translucent glass chat with sentence bubbles, persistent audio playback, quote replies, search, diaries, favorites and a personal daily space use your own HTTPS backend. Credentials are entered in Settings and the connection token is stored in the iOS Keychain. This repository and its public releases contain no service credentials.

## Current release: 0.8.1

The home screen includes location-based Open-Meteo weather, an editable relationship start date and a sidebar for settings, notification permissions, health summaries and actual web-reading receipts. New shared little notes join the existing diaries, calendar moods and keepsakes. Proactive delivery now uses the Morrow-only backend; Telegram and QQ chat transports are disabled.

The listening room uses two editable avatars, an album-covered vinyl player, timed lyrics, playback modes and a shared queue. QQ Music can be connected through its official web login in an isolated WKWebView. Music-session cookies are stored only in this device's Keychain and sent directly to fixed QQ Music endpoints, never the companion backend. It reads created/collected playlists and liked songs, searches tracks and separately queries account-scoped membership. Failed, empty or mismatched membership responses remain unknown. Playback uses only the audio URL returned for the current account; it cannot confer platform membership or guarantee catalog/quality access.

This is a web-session integration, not an approved QQ Music SDK/native-app OAuth integration. A QQ-account end-to-end test requires the owner to log in on the installed client. NetEase links still open externally. No Mineradio implementation code is bundled. Signed audio URLs stay transient, while only public catalog links and metadata are persisted or shared. Disconnect removes this device's QQ credentials, web data and QQ queue entries.

HTTPS audio and public podcast RSS enclosures, Apple podcast discovery, Apple Now Playing metadata/album art, remote commands and background audio remain supported. Optional listening sharing reports this client's actual song, progress and play/pause state to the companion, acknowledging sharing only after a successful backend response. The two avatars do not imply a second synchronized audio player or another app's actual playback state. The listening counter measures this client's active playback time.

The free AltStore build can request local notification permission and schedule an optional daily reminder. It has no APNs entitlement/provider setup, so server messages sync when the app opens. Direct HealthKit reading is disabled in this signing profile; users can deliberately share or remove manual steps/sleep summaries. Settings must not describe these as already granted health access or closed-app push.

## AltStore Classic updates

Source URL:

```
https://raw.githubusercontent.com/Ssrrrnn/companion-ios/main/altstore-source.json
```

In AltStore Classic, open Sources, tap +, paste the URL and add it. Open Morrow in this source to install/update using the same Apple account. Keep the existing app when updating. Free-account signing and normal AltServer refresh requirements still apply; this source distributes updates, it does not change signing limits.

## Publishing changes

Push client changes under `ios/` to `main`, or run **Build and publish personal iOS app** manually. On the public repository, GitHub Actions builds an unsigned IPA on macOS and publishes it as a versioned GitHub Release. Only the Linux publication job has repository contents write permission. After upload size verification, it advances `altstore-source.json`. Failed builds never update the source.

Every workflow run/attempt supplies a distinct numeric build number; `ios/project.yml` holds the marketing version. Update `RELEASE_NOTES.txt` with each change. IPA metadata, bundle identifier, version, minimum iOS and privacy permission descriptions are read from the built archive. A source update cannot replace newer client code on main. Older releases remain downloadable.

The IPA is unsigned so AltStore can sign it locally. Do not add personal tokens or backend credentials to the public repository. A signed distribution pipeline needs explicit entitlement inspection before using this publisher.

## Interface and personal space

Version 0.2 adds avatars, wallpaper, bubble colors, adaptive light/dark appearance, anniversary, daily moods and little notes. Manual keepsakes and personal settings remain on the device; diary and bot favorites use the existing server. No additional paid API is used. Search covers the recent history returned by the server.

Every release also compiles the app for an iOS simulator and captures actual light/dark chat and home previews using synthetic DEBUG-only content. Release publication waits for both builds. See [design references](docs/UI_REFERENCES.md).

## Local build on a Mac

Install Xcode and XcodeGen, then run `bash ios/build.sh`. The output is `ios/build/Companion.ipa`. This client requires iOS 18 or later.

Version 0.3 uses a floating glass dock and cards, shared photo/gradient wallpaper with blur and shade controls, assistant sentence bubbles, Return-to-send, and real stack navigation with edge back gestures. iOS 18 uses translucent material; native Liquid Glass is used only when built with a supporting SDK and running iOS 26+. Voice remains one recording per original reply, attached to its first sentence.

Version 0.4 removes the home resume-chat panel and expensive per-row blur/shadows. Incremental sentence caching and isolated audio progress reduce main-thread redraw work. A native local reading room imports UTF-8/UTF-16 TXT, Markdown and text PDFs (up to 8 MB / one million characters), remembers progress, bookmarks and user notes, and previews selected excerpts before appending them to the chat draft. Only the user's deliberate send shares that excerpt with their existing backend. EPUB, OCR and automatic in-book AI annotations are not yet supported. Optional foreground battery sampling is local; timestamped snapshots can be manually shared. No HealthKit capability, continuous tracker, autonomous server agent or SillyTavern integration is shipped. Existing server/personality stays unchanged and no new paid service is required by these client features. Actual AI chat still uses the existing service's normal token costs.
# 0.5 手机能力与共享月历

更新后进入「他的手机权限」。电量分享和日历读写分别开启；日历还需 iOS 系统授权，并选择分享哪些日历、日程写入哪个日历。没有开启的功能不会上传。仅同步所选日历未来 30 天的标题、时间和日历名，不读取备注、地点或参与者。

心情记录存入共享月历，不会自动发送聊天消息。自己的记录可以编辑或删除，伴侣的记录分开显示；断网记录保留在手机并在连接后重试。旧心情记录首次打开时迁移。后端记录属于固定账号，不接受客户端更换账号或冒充另一方。

后端向模型提供结构化工具，添加日程必须由已绑定手机通过 EventKit 执行并回传保存结果。任务和对应共享记录一起入库；手机回执与任务状态一起更新。重复聊天请求和重复执行使用同一操作编号，日历内的操作标记可在执行中断后防止重复创建。

App 前台自动同步、接收任务；iOS 暂停 App 后不能保证即时执行。离线任务显示「待手机执行」，真实保存回执后才显示「已写入手机日历」。此版本没有接入健康、相册、通讯录、定位或其他 App 的私聊，没有任意执行代码的工具。原有聊天、记忆和语音服务继续使用。
# 0.5.2 大书导入

文件上限提高到 200 MB，正文上限提高到 2000 万字。TXT / Markdown 以 64 KB 字节块读取，保留跨块的 UTF-8 / UTF-16 字符和组合表情；PDF 从文件逐页提取文字。导入时显示进度。

新导入的书存为 UTF-8 正文和页偏移索引；阅读只读取当前页，不在内存中解码整本书。旧 JSON 格式书籍继续兼容，进度、书签、笔记保留。仍仅支持 UTF-8 / UTF-16 TXT、Markdown 和带文字的 PDF；扫描 PDF、EPUB 暂不支持。整书只保存在手机，和伴侣共读仍只发送选定片段。
## Version 0.6 · independent time and shared reading

The existing Railway companion now hosts a durable heartbeat inspired by [claude-cant-sleep](https://github.com/reneyuxi0402/claude-cant-sleep): after 15 minutes without user chat, roughly every 50 minutes (2 hours at 00:00–06:00 Beijing), it chooses one available activity, actually performs it, saves its own mood and daily intentions, and records results. PostgreSQL leases prevent overlapping wakeups and survive deployment. It uses the existing model/API and therefore consumes that API's normal tokens; it is not Claude Code ScheduleWakeup. A pause control is available in His Day.

Available actions are reading uploaded pages, public encyclopedia lookup with source links, writing a saved personal note, and reviewing existing memories without editing them. Chat also receives real structured tools for these actions. No arbitrary shell, accounts, spending, email access or unrelated phone data is granted. Plans, starting entries, successful receipts, empty searches and failures are visibly distinct. Daily plans are also archived as activity entries.

Imported books are automatically synced to the owner-only backend in batches of 20 pages while the app is foregrounded. Both participants have separate progress; the companion must receive the next page and save a response before its progress advances. It can keep reading already-synced pages while the app is closed. Unsynced pages need another foreground session. Whole book text is now stored in the existing PostgreSQL; user bookmarks/notes remain local. Long-press a book to delete its local data and queue removal of shared server text; tombstones prevent uploads in flight from restoring it. Original imported files and already-written activity reflections remain.

Chat bubbles use native Liquid Glass where the SDK/system support it, with translucent material on iOS 18 and an opaque accessibility fallback. The first sentence of each speaker group has an avatar; both avatars and names are editable. Home welcomes change by Beijing time and by saved companion activity.

Location uses When-In-Use authorization. A real structured location call asks the foreground phone to sample with Core Location and acknowledges only after the new timestamped coordinates and accuracy reach the server. Closed/offline phones return last-known/unavailable states, never fabricated real-time positions. No background tracking or HealthKit is enabled.

[Tidal_Echo](https://github.com/anhe2021212-spec/Tidal_Echo) was reviewed for later in-app voice calling: call lifecycle, speech input and TTS playback. No implementation code was copied; this release does not ship calls, CallKit, microphone or speech-recognition permissions.
