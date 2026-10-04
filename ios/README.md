# 小家 · Companion iOS

原生 SwiftUI 个人伴侣客户端，支持 iOS 18 及以上。首页、文字聊天、语音播放、日记与收藏。

## 免费构建

在 Actions 中选择 **Build personal iOS app**，点击 **Run workflow**。完成后下载 `Companion-unsigned` artifact，解压得到 `Companion.ipa`。

该流程只在公开仓库使用标准 GitHub 托管 macOS runner，不上传 Apple 账号、签名证书、模型密钥或用户聊天数据。构建结果为未签名 IPA，由自己的 AltStore/AltServer 在本地签名安装。

## 使用

1. 在 iPhone 的文件 App 保存 IPA。
2. AltStore → My Apps → `+` → 选择 IPA。
3. 打开小家，在设置里填写自己的 HTTPS 伴侣服务地址和连接密钥。

连接密钥保存在设备 Keychain；服务端的 Claude、Fish Audio 和数据库凭据不放进客户端。

首版支持文字输入与语音回复播放；还没有录音输入、实时通话、桌面组件或系统后台推送。前台每 15 秒刷新历史，主动消息可由现有 QQ/Telegram 接收。

## 项目

- `ios/Sources/`：SwiftUI 客户端
- `ios/project.yml`：XcodeGen 项目定义
- `ios/build.sh`：构建未签名 IPA
- `.github/workflows/build-ios.yml`：手动构建流程

只有通用客户端源码公开，实际服务地址、连接密钥、聊天记录和人格配置由各自的私有服务保存。
