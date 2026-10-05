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

当前版本支持文字聊天、语音回复、日记、心情、小纸条、共读、定位天气和一起听。主动消息保存在 Morrow 服务端，打开 App 后同步；原来的 QQ/Telegram 聊天通道已停用。免费签名版本没有服务器后台推送和直接健康读取。

一起听 →「登录并同步歌单」→ 在 QQ 音乐官方网页完成登录 →「完成登录并同步歌单」。页面实时显示是否检测到音乐登录，官网弹窗可返回原页面；加载失败可重新载入，同步失败可在当前页重试。部分歌单读取失败时保留上次同步内容。可读取创建/收藏歌单、我喜欢、歌曲搜索和单独核验的会员状态，尝试播放账号有权限的歌曲；平台未返回会员结果时显示待确认。登录会话只存在本机 Keychain，不上传到伴侣服务。这是网页会话连接，尚未接入 QQ 音乐 SDK 的原生 App 授权；账号完整实测需要用户在安装后的 App 登录。网易云仍为外链方式。

## 项目

- `ios/Sources/`：SwiftUI 客户端
- `ios/project.yml`：XcodeGen 项目定义
- `ios/build.sh`：构建未签名 IPA
- `.github/workflows/build-ios.yml`：手动构建流程

只有通用客户端源码公开，实际服务地址、连接密钥、聊天记录和人格配置由各自的私有服务保存。
