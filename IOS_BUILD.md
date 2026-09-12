# iOS 端构建 / 安装指引

> **前提：iOS 只能在 macOS 上编译。** Flutter 的 iOS 构建必须调用 Xcode 的命令行工具链
> （`xcodebuild`、`xcrun`、`codesign`），这些在 Windows 上不存在，也无法伪造。
> 本仓库里 Windows 上能做的部分**已经做完**（见下面「已完成的适配」），
> 剩下的就是找一台 Mac 执行构建。

---

## 一、已完成的适配（Windows 上已做好）

| 项目 | 状态 |
|---|---|
| `ios/` 工程 | 已生成（`flutter create --org cn.local --project-name bili_live_relay --platforms=ios .`） |
| Bundle Identifier | `cn.local.biliLiveRelay` |
| 部署目标 | iOS 15.0（Flutter 3.47 默认） |
| 签名方式 | Automatic（到 Mac 上只需选自己的 Team） |
| 应用显示名 | `弹幕转发`（`CFBundleDisplayName`），并声明了 `zh_CN` / `en` 本地化 |
| 依赖 | `http` / `crypto` / `shared_preferences` / `qr_flutter` 全部跨平台，无需替换 |
| 代码平台分支 | 无 `Platform.is*`、无 `kIsWeb` 分支，`dart:io`（WebSocket / HttpClient）iOS 原生支持 |
| 明文 HTTP | 无。所有接口为 https；表情 URL 在代码里统一把 `http://` 改写成 `https://`，因此 **不需要配置 ATS 例外** |
| 系统权限 | **不需要任何权限声明**。扫码登录是「用手机 B站 App 去扫本机屏幕上的二维码」，本 App 不调用相机；也不访问相册 / 定位 / 通讯录 |

也就是说 Dart 代码是 100% 复用的，没有任何 iOS 专属改动要做。

---

## 二、在 Mac 上构建并装到 iPhone

### 1. 装工具链

```bash
# Xcode：从 App Store 安装，装完执行一次
sudo xcode-select --switch /Applications/Xcode.app
sudo xcodebuild -runFirstLaunch

# Flutter（macOS 版，别用 Windows 那个目录）
brew install --cask flutter

# CocoaPods（Flutter 的 iOS 插件依赖它）
brew install cocoapods

flutter doctor          # 确认 Xcode 与 CocoaPods 两项是打勾的
```

### 2. 拉依赖并编译

```bash
cd <你的项目目录>/android_app

flutter pub get
(cd ios && pod install)          # 生成 Runner.xcworkspace

# 可选：先跑模拟器验证逻辑
flutter run -d "iPhone 15"
```

### 3. 装到真机

```bash
open ios/Runner.xcworkspace      # 注意是 .xcworkspace，不是 .xcodeproj
```

在 Xcode 里：

1. 左侧选 **Runner** → **Signing & Capabilities**
2. **Team** 选你自己的 Apple ID（没有就 `Add an Account…` 登录）
3. 若 Bundle ID 报冲突，把 `cn.local.biliLiveRelay` 改成你自己的唯一域名前缀
4. 顶部设备选你的 iPhone → 点 **▶ Run**

### 4. 首次打开需要信任证书

iPhone 上：**设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任**

---

## 三、证书与有效期（关键）

| 账号类型 | 真机可用时长 | 分发方式 |
|---|---|---|
| **免费 Apple ID** | **7 天**，过期要重新 Run 一次 | 只能自己的设备、Xcode 直接装 |
| **付费开发者账号（$99/年）** | 1 年 | TestFlight 内测分发 / Ad Hoc 打包 IPA 给指定设备 |

用免费账号时：同一 Apple ID 最多 3 台设备、10 个 App ID，且每 7 天要重新签一次。

---

## 四、没有 Mac 的三条替代路径

1. **云 Mac 按小时租**
   MacinCloud / MacStadium 之类，装好 Xcode 后按上面步骤走，成本最低。
2. **GitHub Actions（macOS runner）自动出包**
   把仓库推到 GitHub，用 `macos-latest` runner 跑 `flutter build ios --release --no-codesign`：
   - 产出**未签名 IPA** → 只有越狱设备 / 用 AltStore、Sideloadly 侧载才能装
   - 想装到普通设备，需要在 Secrets 里放 `p12` 证书 + `mobileprovision` 描述文件，再走 `xcodebuild -exportArchive`
3. **借一台 Mac**：装完工具链后十分钟就能跑起来，最省事。

---

## 五、构建期可能踩到的坑

| 现象 | 原因 / 处理 |
|---|---|
| `pod install` 卡住或超时 | 国内网络问题，可先 `cd ~/.cocoapods/repos && git clone https://mirrors.tuna.tsinghua.edu.cn/git/CocoaPods/Specs.git master` 换镜像 |
| `flutter pub get` 报 authorization failed | 镜像地址结尾的斜杠别漏：`PUB_HOSTED_URL=https://mirrors.tuna.tsinghua.edu.cn/dart-pub/` |
| Xcode 报 `Signing requires a development team` | Signing & Capabilities 里没选 Team |
| 真机 7 天后打不开 | 免费账号签名过期，重新 Run 一次即可 |
| 想改 App 图标 | 替换 `ios/Runner/Assets.xcassets/AppIcon.appiconset/` 下的 png（1024×1024 那张必须有） |

---

## 六、和 Android 的差异速查

| | Android | iOS |
|---|---|---|
| 构建机器 | Windows 可以 | **必须 macOS** |
| 网络权限 | 需在 `AndroidManifest.xml` 声明 `INTERNET` | 默认允许，无需声明 |
| 明文 http | 需 `usesCleartextTraffic` | 需 ATS 例外（本项目全 https，不用配） |
| 安装包 | `app-release.apk` 直接装 | 需签名，走 Xcode / TestFlight / 侧载 |
| 包名 | `cn.local.bili_live_relay`（允许下划线） | `cn.local.biliLiveRelay`（**不允许下划线**，已自动转换） |
