# 弹幕空间（danmaku）

B站直播弹幕 App（Flutter / Android）。扫码登录，看当前直播间的实时弹幕、
**实时在线人数与高能榜头像列表**、**礼物单价与本场礼物价值汇总**，
支持**亮屏保活**挂机与**应用内检测更新**。

- 仓库：<https://gitee.com/xuanduckl/danmaku>
- 包名：`cn.local.bili_live_relay`
- 当前版本：见 `pubspec.yaml`

---

## 功能

| 模块 | 说明 |
| --- | --- |
| 传送门 | 输入房间号 / 粘贴 `live.bilibili.com` 链接 / 跟随 `b23.tv` 分享短链；最近观看；我的爱播 / 技播名单 |
| 弹幕空间 | 当前房间实时弹幕：弹幕、礼物、舰长、醒目留言、进出场；用户标签（房管 / 年费 / VIP / 粉丝勋章 / UL）；表情包；**在线人数 / 礼物金额胶囊**；**亮屏保活开关**；全屏弹幕模式 |
| 观众礼物 | 「实时观众」标签页：在线人数 + 高能榜观众列表（头像 / 昵称 / 贡献值 / 荣耀等级 / 粉丝勋章），支持分页与下拉刷新；「礼物价值」标签页：本场金额总计、各礼物单价与件数明细 |
| 设置 | 弹幕类型筛选、实时数据、本场礼物合计、亮屏保活、检测更新、退出登录 |

### 关于「实时观众」的口径

两个数字含义不同，界面上也分开表述：

- **在线人数**：直播间此刻有多少人在看。来自 `getOnlineGoldRank` 的
  `data.onlineNum`，与 B站客户端顶部显示的是同一个口径。
- **高能榜**：只收录**有贡献值**的观众（投喂 / 点赞 / 发弹幕都会上榜）。
  所以榜上人数一定 **≤** 在线人数，而且只有上榜才拿得到头像与昵称 ——
  B站不对外提供完整观众名册，这是接口能力边界，不是页面丢了数据。

榜单单页上限 50 人，超出部分通过「加载更多」翻页。

### 关于「礼物价值」的口径

价格有三个来源，实测比对 4 个直播间 37 条真实礼物后确认三者**完全一致**：

| 来源 | 说明 |
| --- | --- |
| 礼物面板 `roomGiftConfig` | 权威来源，694 项 / 1.5 MB，按房间缓存一次 |
| 报文 `SEND_GIFT_V2` 的 `gift[5]` | 37/37 与面板一致，用作面板未加载完时的兜底 |
| 明文 `combo_total_coin / combo_num` | B站自己算的单价，同样一致 |

**不能用礼物名查价格**：721 种礼物里有 42 种同名不同价
（「冲浪」同时存在 89900 与 100，「粉丝团灯牌」有 1/100/1000 三档），
所以一律按 `gift_id` 查。计价规则：

- 面板用「金瓜子」计价，**1000 金瓜子 = ¥1**（如 `爱心小熊` price=52000 → ¥52）；
- `coin_type='silver'` 的免费礼物（辣条、小心心等）恒为 0 元，只计数量；
- 实测连击时 `num` 是**本批增量**（同一 combo 连续 `num=1,1,1,1` 总数是 4），
  所以直接相加即可，不需要去重；
- 统计口径是**本次连接期间**收到的礼物 —— B站不提供「开播至今」的接口，
  断线重连或换房间会重新计。

### 关于「亮屏保活」与纯黑配色

亮屏保活用 `FLAG_KEEP_SCREEN_ON`（见 `MainActivity.kt` 的 `setKeepScreenOn`），
**不需要任何权限**，且标志属于窗口、Activity 销毁时自动失效，
不存在「忘记释放导致永不熄屏」的漏电风险。

因为可能长时间常亮挂机，全局配色刻意做成**纯黑 OLED 风格**（`lib/ui/theme.dart`）：
大面积底色是真黑 `#000000`，OLED 上那些像素不发光，既省电又几乎不留残影；
需要分层时用 1px 描边而不是填充色。

---

## 目录结构

```
lib/
├── main.dart                     入口：MaterialApp + 启动闸门（未登录强制扫码）
├── blive/                        B站接口与协议（纯逻辑，不依赖 Flutter UI）
│   ├── api.dart                  HTTP 接口封装：身份、房间、弹幕凭据、表情、观众、礼物面板
│   ├── audience.dart             观众数据模型与响应解析（在线人数 / 高能榜）
│   ├── gift.dart                 礼物价格表、价值累加器与金额格式化
│   ├── client.dart               弹幕 WebSocket 会话：鉴权、心跳、自动重连
│   ├── normalize.dart            原始报文 → 统一 LiveEvent
│   ├── protocol.dart             二进制封包 / 解包 / 粘包切分
│   ├── pb.dart                   极简 protobuf 解析（新版 V2 事件）
│   └── wbi.dart                  WBI 签名
├── core/                         与界面无关的基础设施
│   ├── store.dart                本地存储：登录态、收藏、最近观看、表情表、偏移
│   ├── screen_keeper.dart        亮屏保活的 Dart 封装
│   ├── room_ref.dart             房间号解析（纯数字 / 链接 / 短链 / 分享文案）
│   └── updater.dart              应用内检测更新（Gitee Releases）
├── state/
│   └── relay_controller.dart     共享状态中心：连接、消息流、统计、观众、礼物、亮屏
└── ui/
    ├── theme.dart                纯黑 OLED 主题（防烧屏）
    ├── shell.dart                四模块外壳（PageView + KeepAlive）
    ├── anim.dart                 入场动画、页面过渡
    ├── emoji_text.dart           表情文本渲染
    └── pages/
        ├── login_page.dart       扫码登录
        ├── home_page.dart        传送门
        ├── danmaku_page.dart     弹幕空间
        ├── gift_page.dart        观众礼物（实时观众 + 礼物价值）  ← 新增
        ├── settings_page.dart    设置
        └── manage_page.dart      收藏批量管理
```

测试与脚本：

```
test/
├── blive/audience_test.dart      观众解析（11 条）
├── blive/gift_test.dart          礼物计价与累加（18 条）
├── core/room_ref_test.dart       房间号解析
├── core/room_ref_vj_test.dart    赛事活动页短链
└── widget_test.dart              启动闸门冒烟测试
scripts/
└── release.ps1                   本地一键发版
```

---

## 开发

需要 Flutter 3.47+ / JDK 17 / Android SDK（compileSdk 36）。

```powershell
flutter pub get
flutter analyze          # 应为 No issues found
flutter test             # 应为 All tests passed
flutter build apk --release
```

国内网络建议设镜像：

```powershell
$env:PUB_HOSTED_URL           = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
```

---

## 发版

发布走 **Gitee Releases**（公开仓库，客户端匿名即可读，不需要任何令牌）。

```powershell
pwsh scripts/release.ps1 -Version 1.1.1
```

脚本会：同步 `pubspec.yaml` 与 `lib/core/updater.dart` 的版本号 → 构建 release APK →
在 Gitee 建 tag + Release → 上传 `danmaku-v<版本>.apk` 附件 → 打印直链。

客户端「设置 → 检测更新」读 `releases/latest`，与 `kAppVersion` 比对后
从附件直链下载并唤起系统安装器。

> **历史说明**：早期版本把 GitHub fine-grained PAT 硬编码在 `updater.dart` 里
> 才能读私有仓库的 Release。该令牌随 APK 分发、无法轮换，属于设计缺陷，
> 现已移除；仓库也迁到了 Gitee 公开仓库，无需凭据。
>
> 另外「弹幕记录」模块已整体移除：按天把每条弹幕写进 SharedPreferences
> 需要每 5 秒重写整天的 JSON，房间一热闹就是持续的重 IO，收益不成正比。
> 老版本遗留的 `dlog_*` 数据会在启动时由 `Store.purgeLegacyLogs()` 清掉。

---

## 免责声明

本项目仅用于学习与技术交流，所有数据来自 B站公开接口。请勿用于商业用途或
高频抓取；使用产生的任何后果由使用者自负。
