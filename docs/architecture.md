# PastScreen 架构文档

> 本文档基于 2026-05-18 的代码状态，用中文撰写，覆盖 `PastScreen/` 下全部 Swift 源码（约 15,200 行）。
> 目的：作为后续「砍冗余 + 修架构」的事实基础。

---

## 0. 项目概览

| 项 | 值 |
|---|---|
| 产品定位 | macOS 截图工具（从上一作者继承） |
| 总代码量 | ~15,200 行 Swift |
| 模块数 | 5 个（E1–E5） |
| 系统框架 | AppKit、SwiftUI、Combine、ScreenCaptureKit、Vision、UserNotifications、ServiceManagement、NaturalLanguage、TipKit、QuickLookUI、SQLite3（FTS5） |
| 第三方依赖 | 无 |

---

## 1. 模块依赖图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  用户触发层（E1）                                                            │
│  • 菜单栏点击  → MenuBarContentView → AppDelegate                            │
│  • 全局热键    → HotKeyManager → NotificationCenter → AppDelegate            │
│  • App Intents → ScreenshotIntentBridge → AppDelegate（ForAutomation）       │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  截图核心调度（E2）                                                          │
│  ScreenshotService（1914 行）←→ WindowCaptureCoordinator / SelectionWindow  │
│  选区 → 冻结快照/窗口快照 → 截屏 → 后处理（剪贴板/落盘/入库/通知）          │
└──────────┬────────────┬────────────┬────────────────────────────────────────┘
           │            │            │
           ▼            ▼            ▼
┌──────────────┐ ┌──────────┐ ┌──────────────────────────────────────────────┐
│ UI 层（E4）  │ │ 编辑器   │ │ 截图库 + OCR（E3）                            │
│ 设置/引导/   │ │（E5）    │ │ CaptureLibrary（SQLite+FTS5+语义搜索+缩略图） │
│ 历史浏览/通知│ │ 1722 行  │ │ OCRService（Vision 封装）                     │
└──────────────┘ └──────────┘ └──────────────────────────────────────────────┘

AppSettings（962 行）贯穿所有模块，是全局配置中枢。
PermissionManager / LaunchAtLoginManager / Localization / Logger 为基础服务。
```

---

## E1 入口与生命周期

### 1. 模块职责
管理应用启动、权限检查、全局热键、菜单栏入口、设置持久化、Dock 图标模式、首次启动引导。是产品的「入口门面」和「配置中枢」。

### 2. 文件清单

| 文件路径 | 行数 | 一句话职责 |
|---|---|---|
| `PastScreen/PastScreenApp.swift` | 498 | `@main` 入口 + `AppDelegate` + 8 个 `Notification.Name` + `CaptureTrigger` |
| `PastScreen/Services/HotKeyManager.swift` | 238 | 全局热键监听（NSEvent global/local monitor）+ 三套热键 |
| `PastScreen/Services/PermissionManager.swift` | 258 | 三类权限检查/请求/重试/弹窗（屏幕录制/辅助功能/通知）|
| `PastScreen/Services/LaunchAtLoginManager.swift` | 51 | `SMAppService` 开机自启动开关 |
| `PastScreen/Models/AppSettings.swift` | 962 | 全部 `UserDefaults` 持久化设置（40+ 属性）+ `HotKey` 模型 + 语言切换 |
| `PastScreen/Models/OCRLanguageOption.swift` | 33 | OCR 语言推荐列表（11 种）|
| `PastScreen/Utils/Localization.swift` | 51 | Runtime Bundle swizzling 语言切换 |
| `PastScreen/Utils/Logger.swift` | 68 | DEBUG 条件打印 + 5 个全局便捷 alias |

### 3. 关键类型

**`PastScreenApp: App`**（`@main`）
- `MenuBarExtra` 承载 `MenuBarContentView`
- `Settings` Scene 承载 `SettingsView`

**`CaptureTrigger: String, Sendable`** — 4 case
- `.menuBar` / `.hotkey` / `.appIntent` / `.automation`
- **砍 AppIntents 后可压缩为 2 case 或直接传 Bool**

**`AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject`**（`@MainActor`）
- 属性：`screenshotService: ScreenshotService?`、`permissionManager`、`settings`、`hotKeyManager`、`lastScreenshotPath: String?`（`@Published`）
- 生命周期：`applicationDidFinishLaunching` 按顺序做：单实例检查 → TipKit → ScreenshotIntentBridge 赋值 → `ScreenshotService()` 实例化 → `CaptureLibrary.bootstrapIfNeeded()` → CleanupService / OCRReindexService 启动 → HotKey 监听 → 权限检查 → Dock 模式 → 500ms 后 Onboarding
- 截图入口：`takeScreenshot()` / `captureFullScreen()` / `captureAdvanced()` / `handleHotKeyPressed()` / `handleAdvancedHotKeyPressed()` / `handleOCRHotKeyPressed()`
- 5 个 `performXxxCaptureForAutomation` — **AppIntents 专用，砍 AppIntents 时可删**
- `requestScreenRecordingIfNeeded` — 权限检查 + 弹窗引导
- 菜单动作：`revealLastScreenshot()` / `copyFromHistory(path:)` / `changeDestinationFolder()` / `openPreferences()` / `quit()`
- Dock 管理：`updateActivationPolicy()`（`showInDock` → `.regular` / `.accessory`）

**`HotKeyManager: @MainActor class`** — 单例 `shared`
- `globalEventMonitor` / `localEventMonitor`（`NSEvent.addGlobalMonitorForEvents / addLocalMonitorForEvents`）
- 4 个 `AnyCancellable`：监听 `globalHotkeyEnabled` / `advancedHotkeyEnabled` / `ocrHotkeyEnabled` / `accessibilityStatus`
- `handleHotKeyValues(keyCode:modifierFlags:characters:) -> Bool` — 匹配三套热键，命中则 `NotificationCenter.post(.hotKeyPressed / .advancedHotKeyPressed / .ocrHotKeyPressed)`
- `installGlobalMonitor` / `installLocalMonitor` — `nonisolated static`，在闭包内提取 Sendable 值再跨 actor

**`PermissionManager: @MainActor class, ObservableObject`** — 单例 `shared`
- `@Published`：`screenRecordingStatus` / `accessibilityStatus` / `notificationStatus`
- `checkAllPermissions()` — `CGPreflightScreenCaptureAccess()` / `AXIsProcessTrusted()` / `UNUserNotificationCenter.getNotificationSettings`
- `requestPermission(_:completion:)` — 带 `maxRetries = 3` 的重试逻辑（实际 macOS 弹窗拒绝后不会再弹，重试价值有限）
- `showPermissionAlert(for:)` — `NSAlert` + 打开系统设置

**`LaunchAtLoginManager: @MainActor class`** — 单例 `shared`
- `isEnabled` / `setEnabled(_:)` — `SMAppService.mainApp.register/unregister`

**`AppSettings: @MainActor class, ObservableObject`** — 单例 `shared`，962 行，**项目最大单文件之一**
- 40+ `@Published` 属性，全部 `didSet` → `UserDefaults`
- 分类：
  - **落盘**：`saveToFile`, `saveFolderPath`, `imageFormat`, `screenshotSequence`
  - **窗口边框**：`windowBorderEnabled`/`Width`/`CornerRadius`/`Color`
  - **冻结快照**：`frozenWindowLimitPerDisplay`
  - **剪贴板**：`captureClipboardFormat`, `ocrClipboardFormat`
  - **热键**：`globalHotkeyEnabled`/`globalHotkey`, `advancedHotkeyEnabled`/`advancedHotkey`, `ocrHotkeyEnabled`/`ocrHotkey`
  - **编辑器**：`editingToolOrder`, `enabledEditingTools`, `radialToolIdentifiers`, `radialWheelEnabled`
  - **素材库**：`captureLibraryEnabled`, `captureLibraryStorePreviews`, `captureLibraryAutoOCR`, `captureLibrarySemanticSearchEnabled`, `captureLibraryDebugMode`, `captureLibraryRetentionDays`, `captureLibraryMaxItems`, `captureLibraryMaxBytes`, `captureLibraryLastCleanupAt`
  - **应用规则**：`showInDock`, `launchAtLogin`, `appOverrides`, `appLanguage`
  - **历史/音效**：`captureHistory`, `playSoundOnCapture`
  - **OCR**：`ocrRecognitionLanguages`
- `HotKey: Codable, Equatable, Sendable` — `keyCode` / `modifiers` / `characters`，含 `displayString` / `keyEquivalent`
- `RGBAColor: Codable, Equatable, Sendable` — `r/g/b/a`，支持 `NSColor`/`CGColor`/`SwiftUI.Color` 互转
- `AppLanguage: CaseIterable` — 12 种语言，含 **南极语彩蛋** `.antarctic`（`playAntarcticChirp()` 播放 `gugugaga🐧🐧🐧.m4a`）
- `AppOverride: Codable` — `bundleIdentifier` / `appName` / `format`，用于按应用覆盖剪贴板格式

**`OCRLanguageOption: Identifiable, Hashable, Sendable`**
- `recommended` 静态列表：en-US, zh-Hans, zh-Hant, ja-JP, ko-KR, fr-FR, de-DE, es-ES, pt-BR, it-IT, ru-RU

**`Localization.swift`**
- `SwizzledBundle: Bundle` — 运行时 swizzling 覆盖 `localizedString(forKey:value:table:)`
- `Bundle.setAppLanguage(_:)` — 切换 `.lproj` 目录

**`Logger.swift`**
- `Logger` — `nonisolated static`，`#if DEBUG` 条件打印
- 全局 alias：`logDebug` / `logInfo` / `logSuccess` / `logWarning` / `logError`

### 4. 对外接口

| 暴露方 | API | 调用方（文件:行号示例）|
|---|---|---|
| `AppDelegate` | `takeScreenshot()` | `MenuBarContentView.swift:34` |
| `AppDelegate` | `handleHotKeyPressed()` | `PastScreenApp.swift:126`（NotificationCenter）|
| `AppDelegate` | `performAreaCaptureForAutomation(...)` | `ScreenshotIntentBridge.swift:75` |
| `HotKeyManager` | `startMonitoring()` | `PastScreenApp.swift:117` |
| `HotKeyManager` | `setRecordingHotKey(_:)` | `SettingsView.swift`（快捷键录制）|
| `PermissionManager` | `requestPermission(.screenRecording, ...)` | `OnboardingView.swift:564` |
| `AppSettings` | `shared` + 全部 `@Published` | 全工程 |

### 5. 依赖

- 系统框架：`AppKit`, `SwiftUI`, `Combine`, `UserNotifications`, `ServiceManagement`, `Foundation`, `os.log`
- 本项目：`ScreenshotService`, `CaptureLibrary`, `CaptureLibraryCleanupService`, `CaptureLibraryOCRReindexService`, `ScreenshotIntentBridge`, `OnboardingManager`, `DynamicIslandManager`, `HotKeyManager`, `PermissionManager`, `LaunchAtLoginManager`

### 6. 内部状态与生命周期

`AppDelegate.applicationDidFinishLaunching` 执行顺序：
1. 单实例检查（`runningInstances.count > 1` → `NSApp.terminate`）
2. `UNUserNotificationCenter.current().delegate = self`
3. `Tips.configure()`（macOS 14+）
4. `ScreenshotIntentBridge.shared.appDelegate = self`
5. `screenshotService = ScreenshotService()`
6. `CaptureLibrary.shared.bootstrapIfNeeded()`
7. `CaptureLibraryCleanupService.shared.start()`
8. `CaptureLibraryOCRReindexService.shared.start()`
9. `hotKeyManager.startMonitoring()`
10. 监听 5 个 NotificationCenter 通知
11. `permissionManager.checkAllPermissions()`
12. `updateActivationPolicy()`（Dock / menu bar only）
13. `Task.sleep(500ms)` → `OnboardingManager.shared.showIfNeeded()`

### 7. 可疑 / 冗余 / 可砍点

1. **`CaptureTrigger` 4 case** — `.appIntent` 和 `.automation` 全是 AppIntents 相关，砍后可合并为 2 case 或传 `Bool`。`PastScreenApp.swift:45-50`
2. **AppSettings 40+ 属性中大量与可砍模块绑定**：
   - 编辑器：`editingToolOrder`, `enabledEditingTools`, `radialToolIdentifiers`, `radialWheelEnabled`
   - OCR 热键：`ocrHotkeyEnabled`, `ocrHotkey`, `ocrClipboardFormat`, `ocrRecognitionLanguages`
   - 素材库：`captureLibraryEnabled` 等 8 个属性
3. **南极语彩蛋** (`AppLanguage.antarctic`) — `playAntarcticChirp()` 播放 `gugugaga🐧🐧🐧.m4a`，上一作者个人趣味，可砍。`AppSettings.swift:946-961`
4. **Logger 全局 alias** — `logDebug`/`logInfo` 等只在 DEBUG 构建打印，但散布全工程增加噪音，可用 `os.Logger` 替代。
5. **`AppSettings.captureHistory`** — 旧历史记录（String 数组，最近 10 条），已被 CaptureLibrary 取代，但 `clearHistory` / `addToHistory` 仍在 AppDelegate menu 回调里被调用。`AppSettings.swift:443-448`
6. **AppDelegate 5 个 `ForAutomation` 方法** — AppIntents 专用，砍 AppIntents 时可删。`PastScreenApp.swift:391-475`
7. **PermissionManager 重试逻辑** — `maxRetries=3`，macOS 权限弹窗拒绝后系统不会再弹，重试只是延迟 1s 后检查状态，价值有限。`PermissionManager.swift:62-63`
8. **`requestAllPermissions()`** — 被注释掉的旧方法仍在代码中（335-357 行），是死代码。

### 8. 待澄清问题

1. `captureHistory` 与 CaptureLibrary 是并存还是 migration 后应废弃？
2. `antarctic` 的 `.m4a` 资源是否打包在产物中？体积影响？
3. `HotKeyManager.localEventMonitor` 吞掉事件（返回 `nil`）是否影响 App 内其他键盘响应？
4. `AppSettings` 962 行是否应拆分为多个专题设置文件？

---

## E2 截图核心

### 1. 模块职责
截图流水线总调度：从触发入口 → 选区会话 → ScreenCaptureKit 抓帧 → 冻结快照/窗口命中 → 后处理（剪贴板/落盘/入库/通知）。是产品的**绝对核心**，也是代码量最大的单文件所在。

### 2. 文件清单

| 文件路径 | 行数 | 一句话职责 |
|---|---|---|
| `PastScreen/Services/ScreenshotService.swift` | 1914 | 截图流水线总调度（5 个入口、3 种 mode、冻结快照、自动化、落盘/剪贴板/通知/入库）|
| `PastScreen/Services/WindowCaptureCoordinator.swift` | 396 | Quartz 命中测试 + ScreenCaptureKit 单窗口截图与边框渲染 |
| `PastScreen/Views/SelectionWindow.swift` | 449 | 多屏选区 overlay 与 hover 命中预览，向 service 回调矩形/窗口/取消 |

### 3. 关键类型

**`ScreenshotService: @MainActor class, NSObject, SelectionWindowDelegate`**（1914 行）
- 实例属性（按主题）：
  - 上下文 app：`previousApp: NSRunningApplication?`、`appBundleID`、`appCategoryMap`
  - 选区会话：`selectionWindow: SelectionWindow?`、`selectionSessionID: UUID?`、`windowSnapshotTask: Task<Void, Never>?`
  - 冻结快照：`frozenDisplaySnapshots: [CGDirectDisplayID: SendableCGImage]`、`frozenWindowSnapshots: [CGWindowID: FrozenWindowSnapshot]`
  - 模式状态：`captureMode: CaptureMode`（`.quick`/`.advanced`/`.ocr`）、`captureTrigger: CaptureTrigger`
  - 自动化：`automationRequest: AutomationRequest?`
  - UI 状态：`isShowingEditor = false`
- 公开入口（5 个）：`captureScreenshot(trigger:)` / `captureAdvancedScreenshot(trigger:)` / `captureOCRScreenshot(trigger:)` / `captureFullScreen(trigger:)` / `captureWindowUnderMouse(trigger:mode:)`
- `SelectionWindowDelegate` 三回调：`selectionWindow(_:didSelectRect:)` / `didSelectWindow:` / `selectionWindowDidCancel(_:)`
- 冻结快照：`prepareFrozenDisplaySnapshotsWithScreenCaptureKit()` / `prepareFrozenWindowSnapshotsWithScreenCaptureKit(excludingWindowIDs:)`
- 6 个 `perform*` 方法：`performCapture` / `performAdvancedCapture` / `performOCRCapture` / `performWindowCapture` / `performAdvancedWindowCapture` / `performOCRWindowCapture`
- 后处理：`handleSuccessfulCapture` / `handleAdvancedCapture`（创建 `ImageEditingWindow`）/ `handleEditedImage` / `performOCRFrozenCapture` / `handleOCRResult`
- 落盘：`saveToDiskAsync`（`Task.detached(.utility)`）/ `saveToFile`（`nonisolated static`）/ `saveToFileAndGetPath`
- 自动化：`beginAutomationRequest` / `postAutomationResult` / `completeAutomationIfNeeded` / `writeAutomationFileAndPost` / `writeAutomationFile`
- 剪贴板：`copyToClipboard` / `makePNGClipboardData` / `makeMarkdownImageReference` / `makeMarkdownCodeBlock`
- `frozenCapture(for:)` — 在 display snapshot 中裁切矩形

**`WindowCaptureCoordinator: @MainActor final class`**（396 行）— 单例 `shared`
- `hitTestFrontmostWindow(quartzPoint:excludingPIDs:excludingWindowIDs:skipSelfWindows:) throws -> WindowHitTestResult`
- `hitTestFrontmostWindowAtMouse(...)` — mouse-location 便捷封装
- `captureWindow(with: CGWindowID, applyBorder:) async throws -> WindowCaptureInfo`
- `captureWindow(using: WindowHitTestResult, applyBorder:) async throws` — 便捷封装
- `addBorderIfNeeded(to:borderPoints:cornerRadiusPoints:scale:color:)` — CGContext 重绘加边框
- 辅助类型：`WindowHitTestResult`（`Sendable`）、`WindowCaptureInfo`（`Sendable`）、`EdgeInsetValues`（`NSEdgeInsets` 的 Sendable 替身）、`WindowCaptureError`（6 case）、`QuartzSpace`（坐标转换）

**`SelectionWindow: NSWindow`**（449 行，**逻辑容器，自身不是视觉窗口**）
- 内部 `overlayWindows: [OverlayWindow]`，**每屏一个 `OverlayWindow`**（`NSPanel`，`borderless + nonactivatingPanel`）
- `SelectionOverlayView: NSView` — 真正处理 mouseMoved / mouseDown / mouseDragged / mouseUp / rightMouseDown，绘制冻结背景 + 蒙层 + hole rect + 描边
- `SelectionWindowDelegate` 协议 — 三回调（矩形/窗口/取消）
- ESC 取消：三条路径（`keyDown` / `escapeKeyMonitor` 全局监听 / `OverlayWindow.keyDown` 透传）

### 4. 对外接口

| 暴露方 | API | 调用方 |
|---|---|---|
| `ScreenshotService` | `captureScreenshot(trigger:)` | `AppDelegate`（菜单/热键）|
| `ScreenshotService` | `captureAdvancedScreenshot(trigger:)` | `AppDelegate` + `TutorialView` |
| `ScreenshotService` | `captureOCRScreenshot(trigger:)` | `AppDelegate`（热键）|
| `ScreenshotService` | `captureFullScreen(trigger:)` | `AppDelegate` |
| `WindowCaptureCoordinator` | `hitTestFrontmostWindowAtMouse` | `SelectionOverlayView.resolveWindowHit` |
| `WindowCaptureCoordinator` | `captureWindow(using:applyBorder:)` | `ScreenshotService.performWindowCapture` 等 |
| `SelectionWindow` | `SelectionWindowDelegate` 协议 | `ScreenshotService`（自身实现）|

### 5. 依赖

- 系统框架：`Foundation`, `AppKit`（`@preconcurrency`）, `CoreGraphics`, `SwiftUI`, `UserNotifications`, `ScreenCaptureKit`（`@preconcurrency`）, `Vision`, `QuartzCore`
- 本项目：`AppSettings.shared`（大量）, `CaptureLibrary.shared.addCapture`, `OCRService.recognizeText`, `ImageEditingWindow`, `DynamicIslandManager.shared.show`, `ScreenshotIntentBridge.AutomationReturnType`, `SendableCGImage`, `PermissionManager`
- **可疑 import**：`ScreenshotService.swift` `import Vision` 和 `import SwiftUI` — 本文件未直接使用 Vision API（OCR 已委托给 `OCRService`），也未直接使用 SwiftUI 类型。

### 6. 内部状态、生命周期与并发

**`selectionSessionID` 守卫机制**：`beginSelectionSession()` 生成 UUID，`endSelectionSession()` 取消旧任务。所有 `await` 之后写 `self` 状态前都 `guard isCurrentSelectionSession(sessionID)`。

**`Task.sleep` 硬等待清单**（共 4 处）：
- `ScreenshotService.swift:190` — 150ms，选区矩形后等 overlay 视觉消失
- `:237` — 150ms，窗口选择路径同上
- `:329` — 100ms，`scheduleSelectionCleanup` 延迟清理
- `:510` — 50ms，等 overlay 的 `windowNumber` ready

**`MainActor.run` 与 `Task { @MainActor }`**：出现 >15 处，所有跨 actor 写状态都通过 MainActor 跳转。

**`NotificationCenter.post`**：`.captureFlowEnded` / `.screenshotCaptured` / `.automationCaptureCompleted`

**`SelectionWindow` 多屏 overlay 生命周期**：`init` → `setupMultiScreenOverlays()`（遍历 `NSScreen.screens`）→ `show()`（`orderFrontRegardless` + ESC 全局监听）→ `hide()`（`orderOut` + 移除监听）→ ARC 释放。

### 7. 调用图

```
触发入口（AppDelegate / TutorialView / MenuBar / ScreenshotIntentBridge）
   │
   ├─→ captureScreenshot / captureAdvancedScreenshot / captureOCRScreenshot
   │       └─→ startSelectionFlow(overlayConfiguration:)
   │               ├─→ beginSelectionSession() → UUID
   │               ├─→ prepareFrozenDisplaySnapshotsWithScreenCaptureKit()
   │               │       └─→ 串行 for 每屏: captureDisplaySnapshot() ← SCScreenshotManager
   │               ├─→ SelectionWindow(frozenScreenshots:) → show()
   │               └─→ windowSnapshotTask = Task { prepareFrozenWindowSnapshots... }
   │                       └─→ 串行 for 每窗: captureWindowSnapshot() ← SCScreenshotManager
   │
   用户操作 SelectionOverlayView
   │
   ├─ mouseUp 拖框 → onComplete → selectionWindow(_:didSelectRect:)
   │       ├─ window.hide()
   │       ├─ Task.sleep(150ms)
   │       ├─ frozenCapture(for:rect) 命中? → 直接走 frozen 路径
   │       └─ 未命中 → performCapture / performAdvancedCapture / performOCRCapture
   │               └─→ captureWithScreenCaptureKit → captureScreenRegion ← SCKit
   │
   ├─ mouseUp 点击 → onWindowSelect → selectionWindow(_:didSelectWindow:)
   │       ├─ window.hide()
   │       ├─ Task.sleep(150ms)
   │       ├─ frozenWindowSnapshots[windowID] 命中? → 直接走 frozen 路径
   │       └─ 未命中 → performWindowCapture → WindowCaptureCoordinator.captureWindow
   │
   后处理终态
   │
   ├─ handleSuccessfulCapture / handleEditedImage
   │       ├─ copyToClipboard (image | path | markdownImage)
   │       ├─ CaptureLibrary.shared.addCapture
   │       ├─ saveToDiskAsync (Task.detached .utility)
   │       ├─ showSuccessNotification (DynamicIslandManager)
   │       ├─ post .screenshotCaptured / .captureFlowEnded
   │       └─ completeAutomationIfNeeded / writeAutomationFileAndPost
   │               └─ post .automationCaptureCompleted
   └─ handleOCRResult → NSPasteboard.setString → DynamicIslandManager.show
```

### 8. 可疑 / 冗余 / 可砍点

1. **单文件 1914 行的自然子模块边界**（7 个内聚群）：
   - 入口路由层（~150 行）
   - `SelectionWindowDelegate` 路由 + 清理（~170 行）
   - 自动化（~110 行）— **砍 AppIntents 时全删**
   - 选区会话 + 冻结快照流水线（~330 行）— **核心，必留**
   - OCR 分支专属（~180 行）— **砍 OCR 模式时全删**
   - 截屏执行 + 后处理（~690 行）
   - 剪贴板 + 落盘 + 通知 + 前台应用解析（~250 行）

2. **`.advanced` / `.ocr` / `.automation` 的耦合点**：
   - `.advanced`：约 9 处代码块，核心在 `handleAdvancedCapture`（创建 `ImageEditingWindow:1117`）和 `handleEditedImage`
   - `.ocr`：约 10 处，含 3 个 `performOCR*` + `handleOCRResult` + `makeMarkdownCodeBlock` + `showOCRFeedback`
   - `.automation`：约 14 处，含 `AutomationRequest` 类型 + `beginAutomationRequest` + `postAutomationResult` + `completeAutomationIfNeeded` + `writeAutomationFileAndPost` + `writeAutomationFile`

3. **死代码**：
   - `WindowCaptureCoordinator.convertQuartzRectToAppKit(_:)` — 私有，无任何 caller
   - `ScreenshotService.detectFrontmostApp()` — 私有，未调用；附带的 `appCategoryMap`（~50 个 bundleID 映射）也无消费者
   - `deinit` 中 `NotificationCenter.default.removeObserver(self)` — 本类未注册 observer

4. **重复实现**：
   - **两次 `SCShareableContent`**：`WindowCaptureCoordinator.captureWindow` 与 `prepareFrozenWindowSnapshotsWithScreenCaptureKit` 独立调用，再加 `prepareFrozenDisplaySnapshotsWithScreenCaptureKit` 和 `captureScreenRegion`（`SCShareableContent.current`）— 一次 selection flow 最多跑 4 次
   - **两套边框渲染**：`WindowCaptureCoordinator.addBorderIfNeeded` 与 `ScreenshotService.applyFrozenBorderIfNeeded` 结构几乎一致
   - **两套坐标转换**：`QuartzSpace.appKitRect(fromQuartz:)` 与 `visibleWindowIDsByDisplay` 内 local `appKitRect`
   - **截图音 5 处粘贴**：`/System/Library/Components/CoreAudio.component/.../Screen Capture.aif` 在 5 个位置重复
   - **NSBitmapImageRep 落盘逻辑** 在 `saveToFile` / `writeAutomationFile` / `makePNGClipboardData` 三处几乎一样
   - **6 个 `perform*` 方法骨架几乎一致**（`Task { ... capture* ... MainActor.run { handle* } }`），区别仅 `handle*` 不同

5. **`excludeWindowIDs` 参数死传**：`performWindowCapture` / `performAdvancedWindowCapture` / `performOCRWindowCapture` 接收 `excludeWindowIDs` 但内部 `_ = excludeWindowIDs` 不传给 `captureWindow`。

6. **`UndoManager()` 实例在 `ImageEditingView` 创建后未使用**（E5 报告发现），是死代码。

### 9. 待澄清问题

1. `appCategoryMap` + `detectFrontmostApp` 是否是「按 app 智能切换剪贴板格式」功能的半成品？
2. `SelectionWindow` 继承 `NSWindow` 但自身不是视觉窗口（overlay 全在 `overlayWindows` 数组），主窗口是否纯历史包袱？
3. `frozenWindowSnapshots` 生成时传 `applyBorder: false`，命中后才补加边框 — 是性能权衡还是历史遗留？
4. `WindowCaptureCoordinator.captureWindow(with:)` 公开但仅 `captureWindow(using:)` 被调用，是否曾被他处使用？

---

## E3 截图库 + OCR

### 1. 模块职责

**CaptureLibrary** 是一个完整的本地历史浏览子系统：把每次截图作为记录持久化到 SQLite，配套写入磁盘缩略图/预览图、FTS5 全文索引、OCR 文本、自然语言句向量，并提供分页查询、按 App/标签/时间过滤、关键字与语义搜索、置顶、备注、清理、重建索引等。

**OCRService** 是独立的纯函数式 service（基于 Vision 的 `VNRecognizeTextRequest`），**不属于 CaptureLibrary**——它既被 CaptureLibrary 内部用来做自动 OCR / 重建索引，也被 `ScreenshotService`（OCR 截图模式）与 `ImageEditingWindow`（编辑器中的「识别文字」按钮）直接调用。因此即便砍掉整个截图库，OCRService 仍被外部依赖。

### 2. 文件清单

| 文件路径 | 行数 | 一句话职责 |
|---|---|---|
| `Services/CaptureLibrary.swift` | 759 | `@MainActor` 顶层 façade + `actor CaptureLibraryWorker` + legacy migration |
| `Services/CaptureLibrary/CaptureLibraryModels.swift` | 186 | `CaptureItem` 及枚举、Query、Stats、Cleanup、Reindex 候选等数据模型 |
| `Services/CaptureLibrary/CaptureLibrarySearchSyntaxParser.swift` | 407 | 中英文搜索词法解析（`app:` `tag:` `type:` `#标签` `本周` 等）|
| `Services/CaptureLibrary/CaptureLibraryFileStore.swift` | 168 | 磁盘目录（thumbs/previews/originals）+ JPEG 缩略图编码 |
| `Services/CaptureLibrary/CaptureLibraryFTS.swift` | 68 | FTS5 文本拼装、`MATCH` 表达式生成、标签归一化 |
| `Services/CaptureLibrary/CaptureLibrarySemanticSearchService.swift` | 277 | 基于 `NLEmbedding` 的句向量重排序（标记 "M3, Experimental"）|
| `Services/CaptureLibrary/CaptureLibraryClipboard.swift` | 91 | 复制图片 / 复制路径 / 在 Finder 中显示 |
| `Services/CaptureLibrary/Database/CaptureLibraryDatabase.swift` | 210 | `actor CaptureLibraryDatabase`、连接打开、PRAGMA、bind/column helpers |
| `Services/CaptureLibrary/Database/CaptureLibraryDatabaseSchema.swift` | 133 | `schema_migrations` + v1 schema（建表/索引/FTS 虚表）|
| `Services/CaptureLibrary/Database/CaptureLibraryDatabaseQueries.swift` | 595 | 各种 SELECT（分页/FTS/app groups/tag groups/reindex 候选/stats/cleanup 候选）|
| `Services/CaptureLibrary/Database/CaptureLibraryDatabaseMutations.swift` | 489 | INSERT/UPDATE/DELETE/FTS upsert/标签事务 |
| `Services/CaptureLibraryCleanupService.swift` | 60 | 6 小时定时器，按策略调用 `runCleanup` |
| `Services/CaptureLibraryOCRReindexService.swift` | 284 | 监听 OCR 语言变化，后台分批重跑 OCR 与游标持久化 |
| `Services/OCRService.swift` | 312 | Vision OCR 同/异步封装、语言归一、ROI、中文优先级 |

合计约 **4,039 行**，占全项目 **~27%**。

### 3. 关键类型

**`CaptureLibrary: @MainActor final class`** — 单例 `shared`
- `private let worker = CaptureLibraryWorker()`
- `pendingJobs` / `maxPendingJobs = 8`、`pendingIndexJobs` / `maxPendingIndexJobs = 2`
- `enqueue(priority:operation:)` — `Task.detached(.utility)` 投递到 worker actor
- 核心方法：`addCapture(...)`、`fetchItems(query:limit:offset:)`、`fetchAppGroups` / `fetchTagGroups`、`setTags` / `updateNote`、`requestOCR`、`deleteItems`、`clearAll`、`runCleanup(policy:)`

**`CaptureLibraryWorker: actor`**
- `fileStore: CaptureLibraryFileStore?`、`database: CaptureLibraryDatabase?`
- `prepareIfNeeded()`、`addCapture(job:)`、`migrateLegacyHistoryIfNeeded`
- `notifyChanged()` — fire-and-forget post `.captureLibraryChanged`

**`CaptureLibraryFileStore: struct, Sendable`** — 全部 `nonisolated`
- 根目录：`~/Library/Application Support/CaptureLibrary/`
- `library.sqlite3`、`thumbs/<UUID>.jpg`（maxDim 320，质量 0.82）、`previews/<UUID>.jpg`（maxDim 1600，质量 0.86）、`originals/`（预留，但 `addCapture` 不写入）

**`CaptureLibraryDatabase: actor`**
- `db: OpaquePointer?`（`nonisolated(unsafe)` 仅供 deinit）
- SQLite 配置：`FULLMUTEX + WAL + busy_timeout=2s + foreign_keys=ON + journal_mode=WAL + synchronous=NORMAL`
- Schema v1：`capture_items` 主表 + `tags` + `capture_item_tags` + `capture_items_fts`（FTS5 虚表，`tokenize='unicode61 remove_diacritics 2'`）

**`CaptureLibrarySearchSyntaxParser: struct`** — 全 `static`
- `apply(_:to:context:)` — 解析 `app:Chrome`、`#标签`、`type:area`、`本周`、`最近三天`、`pinned`、`2024-05-18` 等语法
- 中文支持：中文数字映射（一二两三四五六七八九十）、中文日期（`5月18日`）、中文时间词（`本周/上周/本月/最近三天`）

**`CaptureLibrarySemanticSearchService: actor`** — 单例 `shared`
- `rerank(items:queryText:includeFTSWeight:)` — `finalScore = 0.6 * ftsScore + 0.4 * semanticScore`
- 后端：`NaturalLanguage.NLEmbedding`（`sentenceEmbedding` 回退 `wordEmbedding`）
- 向量以 `Data`（`Float * dim`）写回 SQLite，`SHA-256` 防过期
- **UI 无可见开关，默认全员开启；注释标注 "M3, Experimental"**

**`CaptureLibraryCleanupService: @MainActor final class`** — 单例 `shared`
- `timer: Timer?`，`interval = 6 * 60 * 60`（6 小时）
- `start()` — 立刻跑一次 + 定时

**`CaptureLibraryOCRReindexService: @MainActor final class`** — 单例 `shared`
- 订阅 `$captureLibraryEnabled` 与 `$ocrRecognitionLanguages`，debounce 650ms
- batch 18，每 24 条 sleep 160ms，游标 `(created_at, id)` 持久化到 `UserDefaults`

**`OCRService: nonisolated struct`** — 全 `static`
- `recognizeText(in image: NSImage, region:_, preferredLanguages:_, qos:) async throws -> String`
- `recognizeText(in cgImage: CGImage, imageSize:_, region:_, preferredLanguages:_, qos:) async throws -> String`
- 配置：`recognitionLevel = .accurate`、`usesLanguageCorrection = true`、`minimumTextHeight = 0.004`
- 中文优先级：仅允许 `zh-Hant`/`zh-Hans`/`en-US` 同时存在，其它静默忽略

### 4. 数据模型

**`capture_items` 主表列**（`CaptureLibraryDatabaseSchema.swift:46-130`）：
`id`/`created_at`/`updated_at`/`capture_type`/`capture_mode`/`trigger`/`app_bundle_id`/`app_name`/`app_pid`/`selection_w/h`/`external_file_path`/`internal_thumb_path`/`internal_preview_path`/`internal_original_path`/`thumb_w/h`/`preview_w/h`/`sha256`/`is_pinned`/`pinned_at`/`note`/`tags_cache`/`ocr_text`/`ocr_langs`/`ocr_updated_at`/`embedding_model`/`embedding_dim`/`embedding`/`embedding_source_hash`/`embedding_updated_at`/`bytes_thumb`/`bytes_preview`/`bytes_original`

**FTS5 全文索引字段**（`CaptureLibraryFTS.makeText`）：按 `\n` 拼接 `appName` → `tagsCache` → `note` → `ocrText` → `URL(externalFilePath).lastPathComponent`

**`CaptureItem: Identifiable, Hashable, Sendable`** — 全字段 struct，便利属性 `bytesTotal`、`externalFileURL`

### 5. 并发与生命周期

- `CaptureLibrary`：`@MainActor`，计数器维护 + `Task.detached` 投递
- `CaptureLibraryWorker`：`actor`，**串行化**所有数据库/文件 IO
- `CaptureLibraryDatabase`：`actor`，再次串行化 SQLite 句柄
- `enqueue` 并发控制：`pendingJobs >= 8` 时丢弃任务并 `logWarning`
- 自动 OCR：**异步但顺序**。`addCapture` worker 完成 `insertCapture` + `notifyChanged` 后，若 `autoOCR=true` 且没有现成 OCR 文本，**在同一个 Task.detached 里继续** `await OCRService.recognizeText(...)`，识别完再 `updateOCR + notifyChanged`。会延长该任务的占用时间，但不阻塞主线程。

### 6. 搜索体系

| 搜索类型 | 路径 | 备注 |
|---|---|---|
| 普通搜索 | `fetchPage` 非 FTS 分支 | `WHERE` 拼 `is_pinned / capture_type / app_bundle_id / created_at / EXISTS(tags JOIN)` |
| FTS5 搜索 | `JOIN capture_items_fts ON item_id = c.id WHERE capture_items_fts MATCH ?` | `sort=.relevance` 时按 `bm25` 排序 |
| 语义搜索 | `CaptureLibrarySemanticSearchService.rerank` | 内存重排序，`0.6*fts + 0.4*semantic` |

搜索语法示例：
1. `本周 app:Chrome 报错` → `createdAfter=本周一, appBundleID=com.google.Chrome, searchText="报错"`
2. `pinned #设计 type:area 5月18日` → `pinnedOnly=true, tag="设计", captureType=.area`
3. `最近三天 微信` → `createdAfter=now-3day, searchText="微信"`

### 7. 对外接口

| API | 调用方（文件:行号）|
|---|---|
| `CaptureLibrary.shared.bootstrapIfNeeded()` | `PastScreenApp.swift:105` |
| `CaptureLibrary.shared.addCapture(...)` | `ScreenshotService.swift:813/1178/1265/1403/1493` |
| `CaptureLibrary.shared.updateExternalFilePath(for:path:)` | `ScreenshotService.swift:1441/1531` |
| `OCRService.recognizeText(...)` | `ScreenshotService.swift:828/1193/1280`、`ImageEditingWindow.swift:1231` |
| `CaptureLibraryView`（UI） | `fetchItems`/`fetchAppGroups`/`fetchTagGroups`/`setTags`/`updateNote`/`deleteItems`/`requestOCR` 等 |

### 8. 可疑 / 冗余 / 可砍点

1. **代码量占比 27%**。如果产品定位回到「纯截图 + 剪贴板/落盘工具」、不要历史浏览，**整个模块可整体删除**。
2. **「砍 CaptureLibrary 必须删」的文件**：
   - `Services/CaptureLibrary.swift` + `Services/CaptureLibrary/` 整目录（9 个文件）
   - `Services/CaptureLibraryCleanupService.swift`
   - `Services/CaptureLibraryOCRReindexService.swift`
   - `Views/CaptureLibraryView.swift`
3. **「砍了 CaptureLibrary 但仍然要保留」**：`OCRService.swift` — 被 `ScreenshotService` 的 OCR 截图模式与 `ImageEditingWindow` 直接使用，独立可用。
4. **语义搜索子系统**：277 行 + 5 个 `embedding_*` 列 + `updateEmbedding` 流水。UI 无开关，默认开启，复杂度高、收益不明，**首批可砍候选**。
5. **OCR 重建索引服务**：大多数用户开机后几乎不工作（`appliedLangsKey == targetLangsKey` 时立刻返回），但设置变更后会扫一遍整库重 IO。
6. **FTS 与所有字段强耦合**：`updateOCR`/`updateNote`/`setTags`/`updateExternalFilePath` 都同步 `rebuildFTS(for:)`。砍掉搜索功能后这套 upsert 链路全部可去。
7. **疑似不被调用的方法**：
   - `CaptureLibraryDatabase.fetchRecent(limit:)` — 范围内 grep 未见使用
   - `Worker.migrateLegacyHistoryIfNeeded` — 一次性迁移，跑过后变死代码
   - `Worker.clearPreview` / `fetchUnpinnedPreviewCandidates` — 仅 `runCleanup` 在 `maxBytes` 超限时使用，路径较冷

### 9. 待澄清问题

1. `internal_original_path` 列、`originalsURL` 目录在 `addCapture` 中始终为 `nil`——是被废弃的预留还是仍被外部使用？
2. 语义搜索是否真的对用户可见？`CaptureLibraryView` 总是调 `rerank`，但是否有性能/体积代价？
3. `setTags` 用了 `BEGIN IMMEDIATE` 事务，但 `insertCapture` 同时插主表+FTS 却无显式事务——有意为之还是漏洞？

---

## E4 UI 层（非编辑器）

### 1. 模块职责
覆盖菜单栏入口、设置面板、首次启动引导、应用内使用指南、素材库浏览/详情、截图后的两类轻量反馈样式（菜单栏 pill / 屏幕右上角通知卡片），以及共享的 Liquid Glass 视觉风格组件库。

### 2. 文件清单

| 文件路径 | 行数 | 一句话职责 |
|---|---|---|
| `Views/CaptureLibraryView.swift` | 1192 | 素材库窗口：侧栏分组、列表/网格、详情面板、搜索/语义重排、OCR/标签/笔记编辑 |
| `Views/SettingsView.swift` | 1239 | 设置窗口主入口与 5 个 Tab（通用/截图/编辑/存储/应用规则），含快捷键录制器与拖拽排序 |
| `Views/OnboardingView.swift` | 645 | 首次启动 6 页引导（欢迎/屏幕录制/辅助功能/存储/应用规则/剪贴板）|
| `Views/TutorialView.swift` | 457 | 应用内使用指南窗口（权限状态、快捷键展示、试用截图、常见问题）|
| `Views/CustomNotificationView.swift` | 201 | 右上角自定义 `NSPanel` 通知（标题+消息+在 Finder 显示）|
| `Views/DynamicIslandView.swift` | 61 | 菜单栏临时 pill（`✓ 已保存` / `✕ 失败`），3 秒自动消失 |
| `Views/MenuBarContentView.swift` | 166 | 菜单栏下拉菜单：截图入口、最近 10 条、目标文件夹、设置、退出 |
| `Components/LiquidGlassComponents.swift` | 209 | 共享的 `glassContainer` modifier、`GlassCard`、`GlassButton`、`BlurOverlay` 等 |
| `Tips/QuickCaptureTip.swift` | 20 | TipKit `Tip`，定义快速截图提示气泡 |

### 3. 关键 View

**`CaptureLibraryWindow` + `CaptureLibraryManager`**（`CaptureLibraryView.swift:13/19`）
- `CaptureLibraryWindow: NSWindow`，`CaptureLibraryManager: @MainActor` 单例
- 内容：`NSHostingController<CaptureLibraryRootView>`
- 数据源：`@StateObject CaptureLibraryViewModel`，监听 `.captureLibraryChanged` 做 220ms debounce 刷新
- UI 层级：`NavigationSplitView { sidebar / browseList / inspector }` 或 `LazyVGrid` 或 `HSplitView`
- 详情面板：预览图、info 卡片、ocrDebugCard（仅 debug 模式）、metadataEditor（标签+备注）、actions（复制/Finder/置顶/删除）
- 搜索：`.searchable` + `CaptureLibrarySearchSyntaxParser` + `CaptureLibrarySemanticSearchService.rerank`（最大 800 候选）

**`SettingsView`**（`SettingsView.swift:77`）
- `TabView { GeneralSettingsView / CaptureSettingsView / EditorSettingsView / StorageSettingsView / AppsSettingsView }`
- 每个 Tab 直接双向绑定 `settings.*`
- 快捷键录制：`HotKeyRecorderView` + `HotKeyManager.shared.setRecordingHotKey`
- 存储 Tab：`CaptureLibraryCleanupService.shared.runNow()` / `CaptureLibrary.shared.clearAll()`

**`OnboardingWindow` + `OnboardingManager`**（`OnboardingView.swift:16/24`）
- 6 页：`welcome` / `screenRecording` / `accessibility` / `autoCleanup`（实际已是「选择存储目录」）/ `appRules` / `clipboard`
- `borderless + fullSizeContentView` 浮窗，圆角 20
- 权限页：轮询 `SCShareableContent.current` / `AXIsProcessTrusted()`
- `hasSeenOnboarding` UserDefaults 控制只显示一次
- 14 处 `NSLog("🔑/🔍/✅/...")` 调试残留

**`TutorialWindow` + `TutorialManager`**（`TutorialView.swift:11/17`）
- `titled + fullSizeContentView` 设置面板风格
- 权限行：请求失败回退到 `x-apple.systempreferences:` deeplink
- `tryQuickCapture` / `tryAdvancedCapture` — 依赖 `(NSApp.delegate as? AppDelegate)?.screenshotService`，**但在 `TutorialContentView` 中找不到调用源**，是预留功能

**`CustomNotificationManager` + `CustomNotificationContentView`**（`CustomNotificationView.swift:99/15`）
- `NSPanel`（`.nonactivatingPanel + .borderless`，固定 360×100，屏幕右上角）
- **全工程 grep 无外部调用方**，属于历史遗留/被 `DynamicIslandManager` 取代

**`DynamicIslandManager`**（`DynamicIslandView.swift:12`）
- 纯 AppKit，用 `NSStatusBar.system.statusItem(withLength: .variableLength)` 临时挂 pill
- 当前**广泛使用**：截图保存成功（3s）、剪贴板复制（1.5s）、素材库复制（1.5-1.6s）、错误（2s）、OCR 反馈，共 11 处调用点

**`MenuBarContentView`**（`MenuBarContentView.swift:5`）
- 宿主于 `MenuBarExtra`
- 截图入口 → `app.takeScreenshot` / `captureAdvanced` / `captureFullScreen`
- 「打开素材库…」→ `CaptureLibraryManager.shared.show()`
- 「显示上一张截图」→ `app.revealLastScreenshot()`
- 「最近 10 条」子菜单 → `CaptureLibrary.shared.copyImageToClipboard(item:)`

**`LiquidGlassComponents`**（`Components/LiquidGlassComponents.swift`）
- `glassContainer` modifier — 被 SettingsView / TutorialView / CaptureLibraryView / CustomNotificationView / OnboardingView / ImageEditingWindow 大量使用
- `GlassCard` — 同上
- `BlurOverlay` — OnboardingView 在用
- **`GlassButton`、`VibrancyText`、`LiquidGlassBackground`、`DimensionLabel`、`Animation.quickSpring`** — 本扫描范围内**未见使用**，需 E2/E5 对照确认是否孤儿

**`QuickCaptureTip`**（`Tips/QuickCaptureTip.swift`）
- `struct QuickCaptureTip: Tip`，条件编译 `#if canImport(TipKit)`
- **全工程 grep 仅命中文件自身**，无 `popoverTip` / `TipView` 触发器 — **当前是孤儿**

### 4. 用户旅程

```
首次启动
  AppDelegate → OnboardingManager.showIfNeeded() → 6 页引导
    → 权限授予 → "开始" → hasSeenOnboarding = true

用户按热键/菜单栏「截取选区」
  MenuBarContentView → AppDelegate → ScreenshotService
    → DynamicIslandManager.show("已保存") (3s)

用户打开素材库
  MenuBarContentView "打开素材库…" → CaptureLibraryManager.show()
    → NavigationSplitView / LazyVGrid / HSplitView
    → 后台监听 .captureLibraryChanged (220ms debounce)

用户打开设置
  MenuBarContentView "设置" → openSettings() → TabView(5 tabs)
```

### 5. 设置项分类

| Tab | 分区 | 关键项 |
|---|---|---|
| 通用 | 常规 | `launchAtLogin`、`showInDock`、`playSoundOnCapture`、`appLanguage`（12 种含南极语）|
| 通用 | 帮助 | "打开使用指南" 按钮 |
| 截图 | 复制 | `captureClipboardFormat`（image/path/markdownImage）、`ocrClipboardFormat`（text/markdownCodeBlock）|
| 截图 | 格式 | `imageFormat`（png/jpeg）|
| 截图 | 窗口边框 | `windowBorderEnabled`/`Width`/`CornerRadius`/`Color` |
| 截图 | 快捷键 | 普通/Advanced/OCR 三套热键，含录制器 |
| 编辑 | 工具栏 | `editingToolOrder` + `enabledEditingTools`，拖拽排序 |
| 编辑 | 径向轮 | `radialWheelEnabled` + `radialDrawingTools`（最多 4 个）|
| 编辑 | OCR | `ocrRecognitionLanguages`（多选 Toggle）|
| 存储 | 存储 | `saveToFile` + `saveFolderPath`（Security Scoped Bookmark）|
| 存储 | 素材库 | `captureLibraryEnabled` 等 8 项 + "立即清理" + "清空素材库" |
| 应用 | 规则 | `appOverrides`（bundleID + format），NSOpenPanel 选 `.application` |

### 6. 历史库 UI 功能（`CaptureLibraryView`）

1. 侧栏：全部/置顶/最近24h + 应用分组（带图标+条目数）+ 标签分组
2. 浏览列表：`LazyVStack` of `CaptureLibraryListRowView`，右键菜单 6 项
3. 搜索结果网格：`LazyVGrid` of `CaptureLibraryGridItemView`
4. 搜索详情：`HSplitView`（窄列表 + inspector）
5. 顶部工具栏：刷新 + 排序 Picker（`.timeDesc` / `.relevance`）
6. 搜索框：`.searchable` + 语法解析 + 语义 rerank（最大 800 候选）
7. 详情面板：Header / 预览大图 / info / ocrDebugCard（仅 debug）/ metadataEditor（标签+备注，450ms 防抖）/ actions

### 7. 通知/反馈样式

- **`DynamicIslandManager`**（菜单栏 pill）：**当前主力**，11 处调用点
- **`CustomNotificationManager`**（右上角卡片）：**全工程无外部调用方**，被 `DynamicIslandManager` 取代，可整文件删除
- **`QuickCaptureTip`**：全工程无触发器，孤儿

### 8. 可疑 / 冗余 / 可砍点

1. **`CaptureLibraryView`** 与 `CaptureLibrary` 强耦合。若砍库，本文件**整体删除**。
2. **`MenuBarContentView`** 的 `CaptureLibraryMenuModel` 也依赖 `CaptureLibrary`，砍库时「打开素材库…」与「最近 10 条」子菜单需同步移除。
3. **`SettingsView` 存储 Tab 中素材库分区**（~100 行）及 `CaptureLibrarySettingsModel` — 砍库时一并清理。
4. **`OnboardingView` 的 `appRules` 页**：纯文案无功能行为，可砍或合并。
5. **`TutorialView.tryQuickCapture / tryAdvancedCapture`**：找不到调用源，是预留功能。
6. **`LiquidGlassComponents` 中疑似孤儿**：`GlassButton`、`VibrancyText`、`LiquidGlassBackground`、`DimensionLabel`、`Animation.quickSpring` — 需对照 E2/E5 确认。
7. **`CustomNotificationManager`** 与 `DynamicIslandManager` 重复实现反馈通知，前者是历史方案，**可整文件删除**。
8. **`QuickCaptureTip`** — 孤儿，可删。
9. **OnboardingView 中 14 处 NSLog 调试残留** — 上一任作者的个人调试标记。
10. **`@AppStorage("captureLibrary.showUnknownAppGroup")`** 等附加开关散落在不同 key 中，未集中到 `AppSettings`。

### 9. 待澄清问题

1. `QuickCaptureTip` 是否曾在旧版本里用 `.popoverTip` 显示过？还是从未接入？
2. `CustomNotificationManager` 是否还在某些非 UI 入口（AppleScript/AppIntent）被调用？
3. `LiquidGlassComponents` 中的 `GlassButton` 等是否被截图选区/编辑器使用？
4. `CaptureLibraryView.presentationMode == .searchDetail` 的 `HSplitView` 嵌 `browseList` 对窄宽度是否合适？

---

## E5 图像编辑器 + AppIntents

### 1. 模块职责

- **图像编辑器**：为 `advanced` 截图模式提供独立的、可绘制标注的二次编辑窗口。
- **AppIntents / 快捷指令**：向「快捷指令.app」暴露 5 个截图能力，允许用户通过 Siri/快捷指令/Spotlight 触发截图并取回结果。

### 2. 文件清单

| 文件路径 | 行数 | 一句话职责 |
|---|---|---|
| `Views/ImageEditingWindow.swift` | 1722 | 图像编辑器（NSWindow + SwiftUI）：笔刷/形状/文字/马赛克/OCR/撤销/环形工具选择器 |
| `AppIntents/PastScreenShortcuts.swift` | 167 | 5 个 `AppIntent` + `AppShortcutsProvider`（中文 Siri 短语）|
| `Services/ScreenshotIntentBridge.swift` | 161 | Intent 与 AppDelegate 之间的异步桥梁（requestID → 通知等待 → 90s 超时）|

### 3. 关键类型

**`ImageEditingWindow: NSWindow`**（`ImageEditingWindow.swift:13`）
- 内部用 `NSHostingView<AnyView>` 承载 SwiftUI
- 构造函数：`init(image:onCompletion:onCancel:)`
- `show()` / `hide()`（`orderOut`）

**`ImageEditingView: View`**（`ImageEditingWindow.swift:111`）
- 大量 `@State`：`editedImage`、`selectedTool`、`selectedColor`、`strokeWidth`、`drawingPaths`、`currentPath`、`mosaicRegions`、`textInputs`、`undoStack`、`redoStack`、`ocrSelectedRect`、`ocrIsProcessing`...
- `UndoManager()` 实例创建（153 行）但**未实际使用** — 所有撤销重做走自定义栈
- 键盘监听：`NSEvent.addLocalMonitorForEvents`（`cmd+z` / `cmd+shift+z` / `cmd+y` / Return）

**`DrawingTool: String, CaseIterable, Codable, Sendable`**（`ImageEditingWindow.swift:1393-1487`）
- case：`pen` / `line` / `rectangle` / `circle` / `arrow` / `mosaic` / `text` / `ocr`
- 被 `AppSettings` 的 `editingToolOrder` / `enabledEditingTools` / `radialDrawingTools` 引用

**`RadialToolPalette` + `RightClickCaptureView`**（`ImageEditingWindow.swift:1512-1710`）
- 右键拖拽呼出的环形工具选择器
- `SectorShape` 自定义 SwiftUI Shape

**5 个 AppIntent**（`PastScreenShortcuts.swift`）
- `CaptureAreaIntent` / `CaptureFullScreenIntent` / `CaptureAdvancedAreaIntent` / `CaptureOCRIntent` / `CaptureWindowIntent`
- 每个 `perform()` 调用 `ScreenshotIntentBridge.shared.captureXxx(returnType:)`
- 返回类型：`some IntentResult & ReturnsValue<String>`
- 参数：`CaptureShortcutReturnType`（`filePath` / `text`）
- `openAppWhenRun: true` — 触发时一定前台拉起应用

**`ScreenshotIntentBridge: @MainActor final class`** — 单例 `shared`
- `weak var appDelegate: AppDelegate?` — 启动时必须赋值，否则抛 `IntentError.appUnavailable`
- `captureXxx(returnType:)` — 5 个公开方法，全部走内部 `capture(kind:returnType:)`
- 工作流：生成 `requestID` → 按 `CaptureKind` 分支调 `AppDelegate.performXxxCaptureForAutomation` → `await awaitAutomationResult(requestID:)`（`NotificationCenter` 监听 `.automationCaptureCompleted`，90s 超时）
- 错误：`IntentError.appUnavailable` / `.timeout` / `.failed(String)`

### 4. 编辑能力清单

| 工具 | 实现 | 来源 |
|---|---|---|
| 自由笔刷 | `Path.addLine` 累积 | 自研 |
| 直线/矩形/圆/箭头 | 同上 | 自研 |
| 马赛克 | `CIFilter.pixellate` + `CIBlendWithMask` | **CoreImage** |
| 文字 | sheet 输入 + 二次点击落位 | 自研 |
| OCR 选区 | 调用 `OCRService.recognizeText` | 外部 |
| 颜色拾取 | SwiftUI `ColorPicker` | 系统 |
| 撤销/重做 | 自定义 `undoStack`/`redoStack` | 自研 |
| 导出 | SwiftUI `ImageRenderer` 渲染合成 | 系统 |
| 环形工具选择器 | 右键拖拽 | 自研 |

**未提供**：高亮、传统 Gaussian Blur、裁剪。

### 5. 与主流程的耦合点

**编辑器入参**：`ImageEditingWindow.init` 接收 `NSImage` + `onCompletion` + `onCancel`。上游调用点在 `ScreenshotService.handleAdvancedCapture`（`ScreenshotService.swift:1117`）。

**编辑器收尾**：`onCompletion` 由持有者调用，`hide()` 只是 `orderOut`，不清理 ScreenshotService 选区会话。

**AppIntents 耦合**：
- `AppDelegate` 5 个 `ForAutomation` 方法（`PastScreenApp.swift:391-475`）
- `ScreenshotService.beginAutomationRequest` / `postAutomationResult` / `completeAutomationIfNeeded`
- `CaptureTrigger.appIntent` / `.automation`（若存在）在 ScreenshotService 内的所有 `switch` 分支
- `Notification.Name.automationCaptureCompleted` 的发送/监听

### 6. 砍 advanced 模式的改动范围

- **删除**：`ImageEditingWindow.swift` 整文件（1722 行）
- **删除类型**：`ImageEditingWindow` / `ImageEditingView` / `EditAction` / `DrawingPath` / `MosaicRegion` / `TextInput` / `RadialToolPalette` / `RadialToolPaletteItem` / `SectorShape` / `RightClickCaptureView` / `EditingToolButton` / `onChangeCompat`
- **删除前需 grep 确认**：`DrawingTool` 枚举 — 可能被 `AppSettings` 的编辑工具设置引用，若别处也用到则保留枚举但删除编辑器引用
- **外部改动**：
  - `ScreenshotService`：`captureAdvancedScreenshot` / `handleAdvancedCapture` / `handleEditedImage` / `performAdvancedCapture` / `performAdvancedWindowCapture`
  - `AppDelegate`：`performAdvancedAreaCapture` / `performAdvancedAreaCaptureForAutomation`
  - `ScreenshotIntentBridge`：`captureAdvancedArea`
  - `PastScreenShortcuts`：`CaptureAdvancedAreaIntent`
  - `SettingsView`：EditorSettingsView Tab 及 `editingToolOrder` / `enabledEditingTools` / `radialWheelEnabled` / `radialDrawingTools`
- **估算**：删除 ~1750 行 + 修改 ~50-150 行

### 7. 砍 AppIntents 的改动范围

- **删除文件**：
  - `AppIntents/PastScreenShortcuts.swift`（167 行）
  - `Services/ScreenshotIntentBridge.swift`（161 行）
  - 整个 `AppIntents/` 目录
- **删除方法**：
  - `AppDelegate` 5 个 `ForAutomation` 方法
  - `ScreenshotService`：`beginAutomationRequest` / `postAutomationResult` / `completeAutomationIfNeeded` / `writeAutomationFileAndPost` / `writeAutomationFile`
  - `CaptureTrigger` 中 `.appIntent` / `.automation` case 及所有 `switch` 分支
  - `Notification.Name.automationCaptureCompleted`
- **估算**：删除 ~510-600 行 + 修改 ~30-80 行

### 8. 可疑 / 冗余 / 可砍点

1. **`ScreenshotIntentBridge.triggerAreaCapture()` / `triggerFullScreenCapture()`** — 无返回值的触发方法，5 个 Intent 都没用到，疑似遗留 API。
2. **`UndoManager()` 实例创建后未使用** — 死代码。
3. **`ImageEditingWindow` 的 `level = .floating` + `isReleasedWhenClosed = false`** — 窗口关闭时谁释放？外部持有者负责，调用关系需确认。
4. **`CaptureShortcutReturnType` 的 `text` case** — 仅 `CaptureOCRIntent` 默认用 `.text`，其它 4 个 Intent 默认 `.filePath`。
5. **`openAppWhenRun: true`** — 所有 5 个 Intent 触发时一定前台拉起应用，对「后台静默截图」场景不友好。

### 9. 待澄清问题

1. `ScreenshotService` 中触发 `ImageEditingWindow` 的具体位置（已确认 `handleAdvancedCapture:1117`，但需验证是否唯一）。
2. `DrawingTool` 枚举是否仅被编辑器/设置使用？
3. `OCRService` 被编辑器调用外，是否还影响砍 advanced 的决策？（不影响，OCRService 独立保留）
4. `Notification.Name.automationCaptureCompleted` 定义位置？（在 `PastScreenApp.swift:19`）

---

## 跨模块数据流

```
用户按下热键 / 点击菜单栏
  │
  ▼
HotKeyManager / MenuBarContentView
  │
  ▼
NotificationCenter.post(.hotKeyPressed) / AppDelegate.takeScreenshot()
  │
  ▼
AppDelegate.performAreaCapture(source:)
  ├─ capturePreviousApp()          → 记录前台 App
  ├─ Task.sleep(50ms)              → 历史遗留等待
  └─ screenshotService.captureScreenshot(trigger:)
       │
       ▼
  ScreenshotService.startSelectionFlow
       ├─ beginSelectionSession()   → UUID
       ├─ prepareFrozenDisplaySnapshotsWithScreenCaptureKit()
       │    └─ 串行 for 每屏: SCScreenshotManager.captureImage
       ├─ SelectionWindow.show()    → 多屏 overlay
       └─ prepareFrozenWindowSnapshotsWithScreenCaptureKit()
            └─ 串行 for 每窗: SCScreenshotManager.captureImage
       │
       用户拖框 / 点窗口 / ESC
       │
       ▼
  selectionWindow(_:didSelectRect:)
       ├─ window.hide()
       ├─ Task.sleep(150ms)         → 等 overlay 消失
       ├─ frozenCapture(for:) 命中? → CGImage 裁切（<5ms）
       └─ 未命中 → performCapture → captureScreenRegion → SCKit 再抓
       │
       ▼
  handleSuccessfulCapture
       ├─ copyToClipboard           → NSPasteboard 写 PNG Data
       ├─ CaptureLibrary.addCapture → async 入库（fire-and-forget）
       ├─ saveToDiskAsync           → Task.detached(.utility) → HEIC/PNG 编码 + 写盘
       ├─ showSuccessNotification   → DynamicIslandManager.show("已保存")
       └─ post .screenshotCaptured / .captureFlowEnded
```

**关键性能路径**（按 wall-clock 贡献）：
| 节点 | 耗时 | 阻塞用户？ |
|---|---|---|
| `saveToFile` PNG 编码 | 150-300 ms | 不（detached），但用户等通知 |
| Display snapshot 串行 | 60-200 ms | **是**（决定选区出现时间）|
| Window snapshot 串行 | 150-500 ms | 部分（burst 完成前选窗走慢路径）|
| `Task.sleep(150ms)` | 150 ms 固定 | **是**（松开鼠标→通知的直接延迟）|
| `Task.sleep(50ms)` | 50 ms 固定 | 是（热键路径）|
| Clipboard PNG 写入 | 50-150 ms | 是（同步写）|

---

## 冗余 / 可砍模块清单（汇总）

按「砍掉后节省代码量」和「对产品核心功能的伤害」排序：

| # | 模块 | 代码量 | 砍后节省 | 风险 | 连锁影响 |
|---|---|---|---|---|---|
| 1 | **AppIntents + ScreenshotIntentBridge** | ~600 行 | 删除 600 行 | 低 | AppDelegate 5 方法 + CaptureTrigger 简化 + ScreenshotService 自动化分支 |
| 2 | **CaptureLibrary 全子系统** | ~4,040 行 | 删除 4,040 行 | 中 | CaptureLibraryView / Settings 存储 Tab / MenuBar 最近 10 条 / Onboarding 部分页面 |
| 3 | **Advanced 模式 + ImageEditingWindow** | ~1,750 行 | 删除 1,750 行 | 低 | Settings 编辑 Tab / AppSettings 编辑器属性 / ScreenshotService advanced 分支 |
| 4 | **OCR 截图模式** | ~300 行（Service 内）| 删除 ~300 行 | 低 | 热键/设置/MenuBar OCR 入口 / ScreenshotService OCR 分支 |
| 5 | **语义搜索（SemanticSearchService）** | 277 行 | 删除 277 行 | 低 | `embedding_*` 列 + `updateEmbedding` 流水，UI 无开关 |
| 6 | **CustomNotificationManager** | 201 行 | 删除 201 行 | 极低 | 孤儿，无调用方 |
| 7 | **QuickCaptureTip** | 20 行 | 删除 20 行 | 极低 | 孤儿，无触发器 |
| 8 | **TutorialView.tryQuickCapture / tryAdvancedCapture** | ~50 行 | 删除 ~50 行 | 极低 | 预留功能，无调用源 |
| 9 | **南极语彩蛋 + .m4a 资源** | ~20 行 | 删除 ~20 行 + 资源 | 极低 | 纯趣味 |

**如果 1-4 全部砍掉**：
- 删除约 **~6,700 行**（占全项目 44%）
- 剩余核心：热键/菜单栏 → 选区 → SCKit 截屏 → 剪贴板/落盘 → DynamicIsland 通知
- 剩余代码约 **~8,500 行**，其中 `ScreenshotService` 可从 1914 行压到 ~1200 行（去掉 advanced/ocr/automation 分支）

**砍除优先级建议**：
1. **P0（立刻）**：AppIntents（1）+ CustomNotificationManager（6）+ QuickCaptureTip（7）— 纯删除，无功能伤害
2. **P1（本周）**：Advanced 模式（3）+ OCR 模式（4）— 需要改 Settings UI 和热键注册
3. **P2（下周）**：CaptureLibrary 全子系统（2）— 最大改动，需确认产品定位
4. **P3（可选）**：语义搜索（5）— 若保留 CaptureLibrary 则单独砍此子系统

---

*文档创建：2026-05-18*
*基于代码版本：Swift 6 严格并发迁移完成*
*模块扫描：E1 主对话直读，E2-E5 Explore subagent 并行扫描*


