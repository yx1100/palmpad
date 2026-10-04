# 掌控板 Palmpad

把 iPhone 或安卓手机变成 Mac 的触控板。手机采集触摸，Mac 端识别手势并生成和自带触控板相同的系统事件，所以从指针、滚动惯性到调度中心和启动台，手感都和触控板一致。

<p>
  <img src="apple/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="96" alt="手机端图标">
  <img src="apple/Mac/Assets.xcassets/AppIcon.appiconset/icon_512x512@1x.png" width="96" alt="Mac 端图标">
</p>

## 功能

- **完整的触控板手势**：单指移动与轻点、双指滚动（带惯性）、双指缩放与旋转、智能缩放、右键、从右边缘轻扫打开通知中心、三指拖移、三指翻页、四指切换空间、调度中心、App Exposé、捏合打开启动台、张开显示桌面。
- **跟随系统设置**：手势开关、跟踪速度、自然滚动等直接读取 Mac「系统设置 › 触控板」，不用单独配置。
- **手势快捷键**：一指按住，另一指在左侧轻点发送 ⌘W，在右侧轻点发送 ⌘Q。手机和 Mac 自带触控板上都能用，在菜单栏开关。
- **三种连接方式**：同一 Wi-Fi、Mac 连接手机热点、数据线。数据线连接时 iPhone 走 usbmuxd，安卓手机走 adb（需打开 USB 调试）。
- **加密配对**：首次连接时在 Mac 上核对 6 位确认码，之后的通信全部加密。
- **手势诊断**：按手势分别在自带触控板或手机上录制，对比系统和掌控板各自识别的结果，用于校准单个手势。

## 系统要求

| 端 | 要求 |
|---|---|
| Mac | macOS 27 |
| iPhone | iOS 27 |
| 安卓 | Android 17（API 37） |

## 构建

Mac 与 iPhone 端用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成工程。先把 `apple/project.yml` 里的 `DEVELOPMENT_TEAM` 改成自己的开发者团队编号。

```bash
cd apple
xcodegen generate
xcodebuild -project MTM.xcodeproj -scheme MTM-Mac -configuration Debug -derivedDataPath build build
xcodebuild -project MTM.xcodeproj -scheme MTM-iOS -configuration Debug -derivedDataPath build-ios -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Mac 端产物为 `apple/build/Build/Products/Debug/Palmpad.app`，复制到「应用程序」文件夹即可。iPhone 端可用 Xcode 或 `xcrun devicectl device install app` 安装到手机。

安卓端需要 JDK 21：

```bash
cd android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

共享代码的测试用下面的命令运行。

```bash
(cd apple/MTMKit && swift test)
(cd android && ./gradlew test)
```

## 使用

1. 打开 Mac 端，菜单栏出现手形图标。按提示在「系统设置 › 隐私与安全性 › 辅助功能」里允许「掌控板」。
2. 手机打开掌控板，选择要连接的 Mac，在 Mac 弹出的窗口里核对确认码后点「允许」。
3. 之后手机打开即自动连接。菜单栏里可以查看连接状态、移除已配对设备、开关手势快捷键、打开手势诊断、设置登录时启动。

小米 HyperOS 的三指截屏等手势会抢走三指触摸。把掌控板加入「游戏加速」，并打开其中的「关闭三指截图」，掌控板在前台时系统就不再响应这些手势。

## 项目结构

```
apple/
  MTMKit/          Swift 包：Wire（通信协议与加密）、Engine（手势识别引擎）及测试
  Mac/             Mac 菜单栏应用：连接管理、事件注入、手势诊断
  iOS/             iPhone 应用：触控区与连接
  project.yml      XcodeGen 工程描述
android/           安卓应用（Kotlin），协议实现与 Swift 端一致
PROTOCOL.md        通信协议说明
vectors.json       Swift 与 Kotlin 两端协议互通的测试数据
```
