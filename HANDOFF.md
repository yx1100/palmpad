# 掌控板 Palmpad 交接文档

本文给接手这个项目的开发者（人或 AI）。读完应能独立构建、调试、校准和修改三端代码。使用说明见 [README.md](README.md)，通信协议细节见 [PROTOCOL.md](PROTOCOL.md)。

## 1. 项目概况

掌控板把手机变成 Mac 的触控板，由三个应用组成：

| 应用 | 目录 | 作用 |
|---|---|---|
| Mac 菜单栏应用 | `apple/Mac` | 接收手机触摸帧，识别手势，向 macOS 注入事件 |
| iPhone 应用 | `apple/iOS` | 全屏触控区，按帧上报触摸 |
| 安卓应用 | `android` | 同上，Kotlin 实现，协议与 Swift 端逐字节一致 |

手机端不识别任何手势，只发送原始触摸（每个触点的编号、坐标、按下与抬起时间）。所有识别都在 Mac 端的 `GestureEngine` 里完成，参数全部按 Mac 自带触控板的实测录制校准。这样两种手机的手感一致，调参只需改 Mac 端。

**当前状态**：功能完整，处于存档状态。最后一轮工作重新校准了指针与滚动，修正了捏合打开启动台和通知中心边缘轻扫的问题；第 9 节列出了还没在真机上确认的改动。

**命名**：产品名为「掌控板」（英文 Palmpad），早期代号 MTM（Mobile Touchpad for Mac）。用户看得到的地方都已改名，内部标识刻意保留旧名，改动会让已有配对、系统权限和网络发现失效：

- 包标识符：`com.yuxin1100.mtm.mac`、`com.yuxin1100.mtm.ios`、安卓 `com.yuxin1100.mtm`（Kotlin 包名 `app.mtm`）
- Bonjour 服务 `_mtm._udp`、日志目录 `~/Library/Logs/MTM`、Xcode 工程名 `MTM.xcodeproj`、方案名 `MTM-Mac` / `MTM-iOS`

## 2. 仓库结构

```
apple/
  project.yml                 XcodeGen 工程描述（MTM.xcodeproj 由它生成，不入库）
  MTMKit/                     Swift 包，Mac 与 iPhone 共用
    Sources/Wire/             协议编解码（Wire.swift）、配对与会话加密（Crypto.swift）、钥匙串（Keychain.swift）
    Sources/Engine/           手势引擎：Types.swift（动作、设置、调参）、Tracker.swift（时钟同步、帧→触点事件）、
                              GestureEngine.swift（状态机）
    Tests/                    EngineTests（27 项）、WireTests（3 项，用 vectors.json 校验）
  Mac/
    App.swift                 入口、菜单栏 UI、命令行参数 -summarize
    Hub.swift                 UDP 服务、配对、会话、触摸→手势→事件的主流水线（全部跑在一个串行队列 q 上）
    USBLink.swift             有线连接：iPhone 经 usbmuxd，安卓经 adb 服务
    Injector.swift            把引擎动作变成 macOS 事件（CGEvent 与私有 IOHIDEvent）
    PrivateHID.h/.m           私有接口：构造 IOHIDEvent、发送系统快捷键、MultitouchSupport 读取自带触控板
    BuiltInTrackpad.swift     在自带触控板上识别手势快捷键（TipTap），并丢弃随之而来的系统轻点
    SystemSettings.swift      读取「系统设置 › 触控板」的偏好，生成 TrackpadSettings
    Diagnostics.swift         诊断：手势目录、录制、注入测试、录制分析（系统与引擎识别结果对比）
    DiagnosticsPanel.swift    诊断窗口（SwiftUI）
    Log.swift                 ~/Library/Logs/MTM/mtm.log 与 status.json
  iOS/
    App.swift                 界面：全屏触控区、状态与设置两个胶囊按钮、配对页、设置页
    TouchSurface.swift        触控视图（全屏 UIView，卡片是其中的一层），按显示刷新率发送帧
    Link.swift                发现、配对、会话、热点信标、USB 监听
android/app/src/main/java/app/mtm/
  MainActivity.kt             界面、TrackpadLayout（卡片与胶囊布局，转交卡片外的触摸）、三指手势冲突提示
  TouchSurface.kt             触控视图，非批量分发，按帧发送
  Link.kt                     与 iOS 端 Link.swift 对应
  Wire.kt                     与 Wire.swift 对应
PROTOCOL.md / vectors.json    协议说明与双端互通测试数据
```

## 3. 数据流

```
手机触控视图 ──Frame（绝对状态，0.01 mm）──▶ 加密 UDP / USB 流 ──▶ Hub
  Hub：ClockSync 把手机时间换算到 Mac 时钟 → TouchTracker 把帧变成触点按下/移动/抬起
     → GestureEngine.handle(delta) 与 tick(now) → [Action] → Injector.perform → macOS
```

- **Frame** 是绝对状态：每帧带全部在按的触点，抬起的触点在之后 150 ms 内重复出现。丢包或重复都不会让状态错乱，`TouchTracker` 负责去重和补齐。
- **ClockSync** 取滑动窗口内（到达时间 − 手机时间）的最小值作为偏移，换算后的时间保持手机端的均匀间隔，并且不会落在未来。
- **GestureEngine** 是纯状态机，没有副作用：输入触点事件和时钟，输出 `Action`。需要定时器时（惯性、三指拖移松手延迟、智能缩放双击窗口、帧停顿补偿）`needsTick` 为真，Hub 以 120 Hz 调用 `tick`。
- **Injector** 只在 Hub 的队列上运行。

## 4. 连接与会话

- UDP 端口 47800，Bonjour `_mtm._udp`；USB 走手机上的 TCP 47801，包前加 2 字节长度。
- **热点**：Mac 连接手机热点时 Bonjour 不可靠，Mac 向默认网关（即手机）发送信标。
- **有线**：iPhone 经 usbmuxd（Xcode 用的同一服务），安卓经 adb 服务（需打开 USB 调试）。有线会话会替换无线会话，拔线后立即回落到 Wi-Fi。
- **配对**：数字比对加承诺值（P-256 ECDH），两端显示同一个 6 位码，用户在 Mac 上确认。配对密钥存钥匙串（安卓存 KeyStore）。
- **会话**：AES-128-GCM，序号严格递增防重放。Mac 收到新会话第一个通过认证的加密包后才切换控制权，旧会话收到 BYE。心跳每 50 ms 一次，1 秒收不到包即断线。
- 菜单栏显示 Mac 的 Wi-Fi 信道。AWDL 会在 149 和 6 信道之间切换，路由器用 149 信道时卡顿最少。

## 5. 手势引擎

### 5.1 模式与分类

模式：`idle`、`pointer`、`pending`、`scroll`、`zoomRotate`、`drag`、`dock(kind)`、`fluid`（通知中心）、`finished`。

- 一根手指进入 `pointer`；第二根落下后进入 `pending`，按手指数和移动方式分类（`classify`）。
- `upgradeWindow`（0.15 s）内后到的手指仍可把刚开始的手势升级，例如两指滚动在第三、四指落下后变成四指轻扫。
- **两指**：质心移动超过 1 mm 为滚动；指距变化超过 1.5 mm 为缩放，转过 2 mm 弧长为旋转；所有手指都从右边缘 6 mm 内落下、向左移动超过 4 mm 为通知中心。边缘判断用每根手指**落下时**的位置，因为从边缘滑入时两根手指先后相差约 90 ms 落下。
- **三指**：开启三指拖移时，最后一根手指落下满 0.15 s 后才开始拖移，等待拇指晚到的情况。
- **四指及以上**：指距变化超过 1.5 mm，且超过移动距离的一半，判为捏合或张开（启动台、显示桌面）；否则为轻扫（空间、调度中心、App Exposé）。轻扫时指距变化不到移动距离的四分之一，捏合时手指中心也会大幅移动，这条比例规则来自录制统计。
- **轻点**：0.25 s 内、移动不超过 2 mm。
- **手势快捷键（TipTap）**：一根手指已按住至少 0.2 s，另一根手指在旁边轻点；两指连线与水平方向夹角不超过 35°（排除放在下方的拇指）。轻点在左侧发 ⌘W，右侧发 ⌘Q。

### 5.2 调参（`Types.swift` 的 `Tuning`）

所有数值都来自自带触控板的录制（macOS 27，M1，跟踪速度 1.5）。改参数前先录制、用数据说话，不要凭手感调。

| 项目 | 现行规则 |
|---|---|
| 指针 | 每毫米点数 =（2.01 + 0.117 × 手指速度 mm/s，上限 35.3）× 跟踪速度倍数；手指移动 0.5 mm 后才开始移动指针 |
| 滚动（手指按着） | 300 mm/s 以下每毫米 6 点，更快时每 mm/s 加 0.04，上限 16 |
| 方向锁定 | 滚动开始时某一方向的移动量超过另一方向 2 倍，整个手势（含惯性）锁定在该方向 |
| 惯性起速 | 抬手时手指速度 ×（5 + 0.05 × 速度，上限 31.5），最高 25000 点/秒 |
| 惯性衰减 | 每 1/60 秒一步。前 7 步每步乘 (1 − 0.0002 × 首步大小)，快甩衰减快、慢扫几乎保持；之后每步 = 上一步 × 0.918 − 0.098，每步最多减 6.3；精确步长小于 0.25 点时结束 |
| 启动台捏合 | 平均指距每变化 10 mm 为进度 1；开始时进度为 ±0.02，符号表示方向 |
| 空间、调度中心 | 移动 66 mm 为进度 1 |
| 通知中心 | 移动 30 mm 为进度 1 |
| 缩放 | 指距每变化 1 mm 放大 0.0315 |
| 帧停顿补偿 | 20 ms 没有新帧时按原速度继续移动指针或滚动，40 ms 内淡出，最多 120 ms，用来掩盖 Wi-Fi 抖动 |

## 6. 事件注入要点（`Injector.swift`）

下面每一条都由录制或实测确认。

- **事件源**：`CGEventSource(.hidSystemState)` 的 `localEventsSuppressionInterval` 必须设为 0，否则每次注入后自带触控板会冻结 0.25 秒。
- **两条路径**：缩放、旋转、轻扫、通知中心等通过私有 `IOHIDEvent` 附在 CGEvent 上发出（`Route.hid`）；不可用时退回到系统快捷键（`Route.keys`）。诊断窗口里可以切换路径做对比。
- **捏合（dock 运动类型 3）的符号**：监听自带触控板时，捏合的进度为正、张开为负，但**注入时必须反过来**：捏合发负值，否则会触发显示桌面。结束速度与进度**符号相反**（滑动类同号），否则快速捏合会被当成往回甩而取消。
- **滑动类结束事件**：系统负载高时 WindowServer 偶尔丢掉结束事件，过渡动画会卡住，所以结束事件会在 0.2 秒和 0.5 秒后各补发一次。
- **滚动事件的三种数值**：
  - 字段 176 是精确步长（单位 10 点，带方向），使用精确滚动的应用读的是它；
  - 字段 96 是整数点数，惯性阶段对精确值**向上取整**（0.3 点也写 1）；
  - 行数（字段 11 与 93）在惯性阶段累计满 10 点才记 1 行。
- **惯性标记字段 173**：开始 1，滑行中 2，自然结束 19，被触摸打断 3（引擎里对应 `MomentumPhase.end` 与 `.stopped`）。缺少它时，应用会在惯性结束后自己再补一段滑动。
- **用力点按**：手机感知不到压力，按录制的事件序列合成；诊断里系统识别得到、引擎识别不到，属于预期。

## 7. 诊断与校准流程

1. 菜单栏 →「手势诊断…」，选一个手势，点「在触控板上录制」做标准动作，或点「在手机上录制」重现问题。
2. 录制保存为 `~/Library/Logs/MTM/diag-<手势>-<trackpad|phone>.jsonl`，每个手势每种来源只保留最新一份。
   - 触控板录制包含自带触控板的原始触点（`mt`）和系统事件（`ev`，含 HID 字段）；
   - 手机录制包含手机帧（`ph`）和掌控板当时发出的动作（`act`）。
3. 窗口里会用当前引擎重新分析录制，触控板录制并排显示「系统识别」和「掌控板识别同样的触摸」。
4. 命令行分析：`Palmpad -summarize <文件> -timeline`，逐条列出两边的识别结果和时间，对不上的那一条就是要查的。
5. 细节分析写 Python 脚本直接读 JSONL，常用字段见下表。

| 字段 | 含义 |
|---|---|
| `ev.cg` | 事件类型：5 移动、22 滚动、29 手势、30 dock、31 通知中心 |
| 字段 99 | 滚动阶段：1 开始、2 变化、4 结束、128 可能开始 |
| 字段 123 | 惯性阶段：1 开始、2 继续、3 结束 |
| 字段 96 / 97 | 整数点数 |
| 字段 176 | 精确步长 |
| 字段 110 | 手势子类型：8 缩放、5 旋转、22 智能缩放、16 翻页、32 用力点按 |
| 字段 123 / 124（dock 事件） | 运动类型与进度 |

触控板录制的事件监听装在硬件层，**录不到掌控板自己注入的事件**。查掌控板发出了什么，要用手机录制里的 `act`。

## 8. 构建、安装与调试

### 构建

```bash
cd apple && xcodegen generate                 # 增删源文件后必须重新生成
xcodebuild -project MTM.xcodeproj -scheme MTM-Mac -configuration Debug -derivedDataPath build build
xcodebuild -project MTM.xcodeproj -scheme MTM-iOS -configuration Debug -derivedDataPath build-ios \
  -destination 'id=<UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew assembleDebug
```

### 安装

- **Mac**：先 `pkill -x Palmpad`，删除旧的 `/Applications/Palmpad.app`，再 `ditto` 复制新产物并 `open`。用 `lsregister -u` 注销编译目录里那份，免得启动台出现两个同名应用。
- **iPhone**：`xcrun devicectl device install app --device <UDID> <Palmpad.app>`。手机锁屏时会安装失败。免费开发者账号的描述文件 7 天过期，过期后应用打不开，重新编译安装即可。必须用 `-destination 'id=<UDID>'`，用 `generic/platform=iOS` 编译时 Xcode 不会生成新的描述文件。
- **安卓**：应用 ID 是 `com.yuxin1100.mtm`，启动用 `am start -n com.yuxin1100.mtm/app.mtm.MainActivity`。

### 无线调试小米

- 配对用手机「无线调试 › 使用配对码配对」弹窗里的端口，连接用无线调试主页面显示的端口，两者不同。
- 如果 adb 报 `No route to host`，原因是 macOS 的本地网络权限：adb 服务成了没有归属应用的进程。在终端里 `adb kill-server` 后再 `adb start-server`，让它从有权限的进程启动。

### 日志

- `~/Library/Logs/MTM/mtm.log`：会话、配对、连接方式、帧停顿。
- `status.json`：当前状态快照。

### 测试

- `cd apple/MTMKit && swift test`：30 项，改引擎必须跑。
- `cd android && ./gradlew test`：协议互通。

## 9. 已知问题与待确认事项

**平台限制**

- **小米三指手势**：HyperOS 的 `MiuiMultiFingerGestureManager` 在三指按下时就抢走触摸，只有游戏模式下、或系统设置 `enable_three_gesture=0` 时例外。普通应用没有权限写这个设置。
  - 解决办法：把掌控板加入「游戏加速」并打开「关闭三指截图」，掌控板在前台时系统会把它设为 0。
  - 验证：`adb shell settings get system enable_three_gesture`，掌控板在前台时应为 0。
  - 安卓应用在检测到三指手势开启时会弹出提示。
- **安卓边缘手势**：系统对每条边最多屏蔽 200dp，横屏时右边缘约一半长度仍可能触发返回手势。
- **用力点按**：手机无法感知压力。
- **iPhone 签名**：免费账号每 7 天要重装一次。可选办法有付费开发者计划，或在 Mac 上加定时任务自动重装（尚未实现）。

**最后一轮修改，尚未在真机上确认手感**

- 指针与滚动按 2026-10-03 的录制重新拟合（第 5.2 节），包括惯性的精确步长、取整方式与行数累计（第 6 节）。
- 通知中心从屏幕最边缘滑入：触控视图已改为全屏（iOS），卡片外的触摸转交给触控区（安卓）。

**录制里观察到、未处理的现象**

- 有一份触控板录制里，系统在识别出滚动手势后没有发出滚动事件，推测是指针下的窗口已滚到尽头。
- 另一份录制里系统惯性都在每步约 6 点时结束，而最新录制显示惯性会一直减到每步约 0.3 点。现行参数采用最新录制。

## 10. 维护约定

- **改识别或手感**：先用诊断录制拿到自带触控板的数据，改完用 `-summarize -timeline` 和 `swift test` 验证，在 `EngineTests` 里补一项能复现问题的测试。
- **注释**：调参的注释写清数值来源，例如「录制显示……」。
- **重命名**：不要改第 1 节列出的内部标识。
- **增删 Swift 源文件**：重新运行 `xcodegen generate`；生成的工程不入库。
- **Git**：在新分支上提交，提交信息末尾只写 `Authored-By: Xin <yuxin1100@foxmail.com>`，不加其他署名。
