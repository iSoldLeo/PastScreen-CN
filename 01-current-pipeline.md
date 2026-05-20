# PastScreen 截图流程现状梳理

> 研究文档，不是实施文档。目的：在动手优化之前，把"按下截图键到文件落盘"的完整链路、每一个参与的文件/类/函数、以及它们当前的串/并/同/异步特性都讲清楚。
>
> 撰写时间：2026-05-18
> 项目代码版本：Swift 6 严格并发迁移完成（spec `swift6-concurrency-migration` Task 1–9 已完成，10–12 因无 Xcode 环境未做最终编译验证）。
> 参考实测数据：见 `scripts/sck_burst_probe/`（macOS 26.5、M 系列 mac）。

---

## 0. 一图概览

```
┌─────────────────────────┐
│ 触发来源                │
│  • 全局热键              │
│  • 菜单栏点击            │
│  • App Intents (快捷指令)│
└──────────┬──────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────┐
│ HotKeyManager / MenuBarContentView / ScreenshotIntentBridge │
│  → NotificationCenter.post(.hotKeyPressed / 等)             │
└──────────┬───────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────┐
│ AppDelegate.handleHotKeyPressed / handleAdvancedHotKeyPressed │
│  • requestScreenRecordingIfNeeded                          │
│  • Task.sleep(50ms)                                        │
│  • screenshotService.captureScreenshot(trigger:)           │
└──────────┬───────────────────────────────────────────────┘
           │
           ▼
┌────────────────────────────────────────────────────────────────────┐
│ ScreenshotService.startSelectionFlow（核心调度）                   │
│                                                                    │
│  并发任务 1（阻塞 UI 出现，~60–200 ms）:                           │
│    prepareFrozenDisplaySnapshotsWithScreenCaptureKit               │
│       → 串行 for 每屏 captureDisplaySnapshot()                     │
│       → 把 frozenDisplaySnapshots[displayID] = SendableCGImage    │
│                                                                    │
│  并发任务 2（UI 显示后才启动）:                                    │
│    SelectionWindow(frozenScreenshots:)                             │
│      • 每屏一个 OverlayWindow，显示冻结背景                        │
│      • 处理 mouse hover / drag / click                             │
│                                                                    │
│  并发任务 3（与 UI 并行）:                                         │
│    prepareFrozenWindowSnapshotsWithScreenCaptureKit                │
│       → visibleWindowIDsByDisplay 选前 N（默认 5/屏，可调，详见 §2.5）│
│       → 串行 for 每窗 captureWindowSnapshot                        │
│       → 把 frozenWindowSnapshots[windowID] = FrozenWindowSnapshot │
└──────────┬─────────────────────────────────────────────────────────┘
           │  用户拖框 / 点窗口 / ESC
           ▼
┌────────────────────────────────────────────────────────────────────┐
│ SelectionWindowDelegate 回调（ScreenshotService）                  │
│  • Task.sleep(150 ms)  ← 等 overlay 视觉消失                       │
│  • frozenCapture(for: rect) 命中？→ 直接走 frozen 路径             │
│  • 未命中 → performCapture / performWindowCapture（再走 SCKit）   │
└──────────┬─────────────────────────────────────────────────────────┘
           │
           ▼
┌────────────────────────────────────────────────────────────────────┐
│ handleSuccessfulCapture / handleAdvancedCapture / performOCR*      │
│  • copyToClipboard（含 PNG 编码到剪贴板）                          │
│  • CaptureLibrary.shared.addCapture（async 入库，不阻塞）          │
│  • saveToDiskAsync                                                 │
│       → Task.detached(.utility) → NSBitmapImageRep → PNG/JPEG 编码 │
│  • showSuccessNotification（Dynamic Island）                       │
│  • automation 模式：writeAutomationFileAndPost                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## 1. 触发层：用户操作 → 启动截图流程

### 1.1 全局热键路径

| 文件 | 关键符号 | 职责 |
|---|---|---|
| `PastScreen/Services/HotKeyManager.swift` | `@MainActor class HotKeyManager` | 单例。订阅 `AppSettings` 三个 hotkey 配置变化（普通 / advanced / OCR），并订阅 `PermissionManager.$accessibilityStatus` 在权限恢复时自动重启监听；启停 NSEvent 全局/本地监听。 |
| 同上 | `installGlobalMonitor / installLocalMonitor`（`private nonisolated static`） | 将 `NSEvent` 这个非 Sendable 类型的字段（keyCode、modifierFlags、charactersIgnoringModifiers）在闭包里就地提取为 Sendable 值再跨 actor 传出。`installLocalMonitor` 返回 `true` 时本地监听闭包会返回 `nil` 吞掉事件，避免触发应用内其他键盘响应。 |
| 同上 | `handleHotKeyValues(keyCode:modifierFlags:characters:)` | 与三套 hotkey（普通、advanced、OCR）做匹配。匹配则 `NotificationCenter.post(.hotKeyPressed / .advancedHotKeyPressed / .ocrHotKeyPressed)`。 |
| `PastScreen/PastScreenApp.swift` | `Notification.Name` 定义 | 共 8 个：`.screenshotCaptured`、`.automationCaptureCompleted`、`.showInDockChanged`、`.hotKeyPressed`、`.advancedHotKeyPressed`、`.ocrHotKeyPressed`、`.captureFlowEnded`、`.captureLibraryChanged`。 |

注意：`HotKeyManager` 用的是 **NotificationCenter 解耦**，不直接调用 `ScreenshotService`。这让 menubar 点击和 hotkey 走同一条下游路径。

### 1.2 菜单栏点击路径

| 文件 | 关键符号 | 职责 |
|---|---|---|
| `PastScreen/Views/MenuBarContentView.swift` | 菜单项点击回调 | 调用 `AppDelegate` 上的封装方法（`takeScreenshot / captureAdvanced / captureFullScreen`），由 AppDelegate 再走 `performAreaCapture / performAdvancedAreaCapture / performFullScreenCapture`，与 hotkey 路径在 AppDelegate 内合流，最终带 `source: .menuBar` 调 `ScreenshotService`。 |

### 1.3 App Intents（快捷指令）路径

| 文件 | 关键符号 | 职责 |
|---|---|---|
| `PastScreen/AppIntents/PastScreenShortcuts.swift` | `CaptureAreaIntent`、`CaptureFullScreenIntent`、`CaptureAdvancedAreaIntent`、`CaptureOCRIntent`、`CaptureWindowIntent` | 5 个 AppIntent，每个 `perform()` 调用 `ScreenshotIntentBridge.shared.captureXxx(returnType:)`（`captureArea / captureFullScreen / captureAdvancedArea / captureOCR / captureWindow`）。 |
| `PastScreen/Services/ScreenshotIntentBridge.swift` | `ScreenshotIntentBridge` | 生成 `requestID = UUID()`，反向调 `AppDelegate.performXxxCaptureForAutomation(requestID:returnType:)`（这些方法先调 `screenshotService.beginAutomationRequest(requestID:returnType:)` 登记请求，再触发实际截图）；然后 `awaitAutomationResult(requestID:timeoutSeconds:)` 内部用 `NotificationCenter.addObserver(forName: .automationCaptureCompleted)` 等结果。默认超时 **90 s**，超时抛 `IntentError.timeout`。 |
| `PastScreen/PastScreenApp.swift` | `AppDelegate.applicationDidFinishLaunching` 内 `ScreenshotIntentBridge.shared.appDelegate = self`（弱引用） | AppIntent 触发的 capture 走和 hotkey 一样的下游路径，区别在 trigger 固定为 `.appIntent` 且最终 `ScreenshotService` 会通过 `postAutomationResult` 派发 `.automationCaptureCompleted` 把 `filePath / ocrText / error` 回传给 bridge。 |

### 1.4 AppDelegate 中转

| 文件 | 关键符号 | 职责 |
|---|---|---|
| `PastScreen/PastScreenApp.swift` | `AppDelegate.handleHotKeyPressed / handleAdvancedHotKeyPressed / handleOCRHotKeyPressed` | 监听三个 NotificationCenter 通知，调 `requestScreenRecordingIfNeeded`，再走对应的 `performXxxCapture(source:)` 共用入口。 |
| 同上 | `performAreaCapture / performAdvancedAreaCapture / performOCRCapture(source:)` | 三个选区类共用入口，参数 `source: CaptureTrigger`。**执行步骤**：(1) `screenshotService.capturePreviousApp()` 记录当前前台 app；(2) `Task { try? await Task.sleep(nanoseconds: 50_000_000) }` 硬等 50 ms；(3) 调 `screenshotService.captureScreenshot(trigger: source)` / `captureAdvancedScreenshot` / `captureOCRScreenshot`。 |
| 同上 | `performFullScreenCapture(source:)` | 全屏入口。**不走 50 ms sleep**——直接同步调 `screenshotService.captureFullScreen(trigger: source)`。 |
| 同上 | `performAreaCaptureForAutomation / performAdvancedAreaCaptureForAutomation / performOCRCaptureForAutomation / performFullScreenCaptureForAutomation / performWindowCaptureForAutomation(requestID:returnType:)` | AppIntent 专用版本（共 5 个）。在调下游前先 `screenshotService.beginAutomationRequest(requestID:returnType:)` 登记请求；trigger 硬编码为 `.appIntent`。其中 `performWindowCaptureForAutomation` 是窗口截图的唯一入口（菜单栏未暴露）。 |

**性能成本**：`capturePreviousApp()` ~µs 级 + `Task.sleep(50ms)` × 1 次 = 固定 50 ms（仅选区类入口，全屏入口无此 sleep）。50 ms 是历史问题（早年权限 alert 不关会拦截事件），现代 macOS 大多场景已不需要；具体历史原因待考。

---

## 2. 调度层：ScreenshotService

`PastScreen/Services/ScreenshotService.swift`（1914 行，单文件）。`@MainActor class ScreenshotService: NSObject, SelectionWindowDelegate`。

### 2.1 三种模式（CaptureMode）

`CaptureTrigger`（在 `PastScreen/PastScreenApp.swift:45-50` 定义）四个 case：`.menuBar / .hotkey / .appIntent / .automation`。

| 模式 | 入口函数 | 行为差异 |
|---|---|---|
| `.quick` | `captureScreenshot(trigger:)` | 直接复制到剪贴板 + 入 CaptureLibrary + 落盘（如果设置开启）。 |
| `.advanced` | `captureAdvancedScreenshot(trigger:)` | 拿到 cgImage 后打开 `ImageEditingWindow` 编辑，编辑完后才保存。 |
| `.ocr` | `captureOCRScreenshot(trigger:)` | 拿到 cgImage 后跑 Vision OCR，把识别文本和图都入库。 |

外加两个"非选区"入口：
- `captureFullScreen(trigger:)` — 直接抓所有 NSScreen 的并集 rect，调 `performCapture`。
- `captureWindowUnderMouse(trigger:mode:)` — 不显示选区窗口，直接 hit-test 鼠标下窗口然后抓。

### 2.2 selection flow 主控函数：`startSelectionFlow(overlayConfiguration:)`

这是性能核心，做了三件事，时间线如下（伪代码，对照源码请看 ScreenshotService.swift:474）：

```
T0: 按键
T0+0:   beginSelectionSession() 取一个 UUID
T0+0:   Task { ... } 启动一个不限定 actor 的 Task
        ↓ async
T0+5:     prepareFrozenDisplaySnapshotsWithScreenCaptureKit() -> [CGDirectDisplayID: SendableCGImage]
            • SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            • for screen in NSScreen.screens {
                captureDisplaySnapshot(screen, scDisplay, [])  ← 串行
              }
T0+~80–200 ms（取决于屏数）: 完成
        ↓
T0+~80–200: await MainActor.run {
              self.frozenDisplaySnapshots = displaySnapshots         // 仍以 SendableCGImage 持有
              self.selectionWindow = SelectionWindow(
                frozenScreenshots: displaySnapshots.mapValues { $0.image }, // 解包为 raw CGImage 给 UI
                overlayConfiguration: ...
              )
              selectionWindow.show()                                  ← 用户首次看到选区
            }
        ↓ 立即启动嵌套 Task
T0+~80–200: windowSnapshotTask = Task {
              // 50 ms 兜底等 overlay windowNumber 就绪
              if overlayWindowIDs.isEmpty { Task.sleep(50ms); 再取一次 overlayWindowIDs }
              prepareFrozenWindowSnapshotsWithScreenCaptureKit(excludingWindowIDs:)
                • SCShareableContent ... 再调一次
                • visibleWindowIDsByDisplay() 每屏取前 max(AppSettings.frozenWindowLimitPerDisplay, 5) 个（默认 5 为下界）
                • for window in content.windows { captureWindowSnapshot ← 串行 }
              await MainActor.run { frozenWindowSnapshots = ... }
            }
T0+~200–600 ms（取决于窗口数）: window snapshots 完成
```

**用户感知点**：
- 按键 → 选区出现 = Display snapshot 串行总耗时 + 一次 main 跳转 ≈ **80–200 ms**
- 选区出现 → 用户点击窗口 = 不阻塞，但若窗口截图未完成会走"事后再抓"慢路径

### 2.3 选区回调（`SelectionWindowDelegate`）

#### `selectionWindow(_:didSelectRect:)`（拖框选区域）

```
T1: 用户松开鼠标
T1+0:   window.hide()
T1+0:   if captureMode != .advanced { restorePreviousAppFocus() }   ← advanced 模式因为接下来要开编辑器，故不立即归还焦点
T1+0:   Task.sleep(150 ms)              ← 硬等待 overlay 视觉消失
T1+150: 如果 frozenCapture(for: rect) 命中
            走 frozen 路径，cgImage 已是缓存
        否则
            performCapture / performAdvancedCapture / performOCRCapture
              → captureWithScreenCaptureKit
                → captureScreenRegion (再做一次 SCKit 截屏)
T1+150–400ms: handleSuccessfulCapture / handleAdvancedCapture / performOCRFrozenCapture
```

#### `selectionWindow(_:didSelectWindow:)`（点击单个窗口）

```
T1: 用户点击
T1+0:   window.hide()
T1+0:   Task.sleep(150 ms)
T1+150: frozenWindowSnapshots[hitResult.windowID] 命中？
            • 命中：applyFrozenBorderIfNeeded → 走 frozen 路径
            • 未命中：performWindowCapture / performAdvancedWindowCapture / ...
              → WindowCaptureCoordinator.captureWindow(using: hitResult)
                → SCContentFilter(desktopIndependentWindow:) + SCScreenshotManager
T1+150–400ms: handleSuccessfulCapture
```

### 2.4 cleanup

```swift
scheduleSelectionCleanup(postCaptureFlowEnded:) {
    Task.sleep(100 ms)                  ← 又一次硬等待
    endSelectionSession()
    selectionWindow = nil
    frozenDisplaySnapshots.removeAll()
    frozenWindowSnapshots.removeAll()
    if postCaptureFlowEnded && !isShowingEditor {
        post .captureFlowEnded         ← advanced 模式编辑器还在显示时不发，等编辑完成后由 handleEditedImage 路径处理
    }
}
```

### 2.5 Selection session 生命周期

`startSelectionFlow` 内部所有跨 actor 写状态的代码都被一组 session 守卫包裹，避免"用户已经按了第二次截图键、但上一轮的 frozen snapshot 异步任务还没退场"导致的状态污染。

| 符号 | 角色 |
|---|---|
| `selectionSessionID: UUID?` | `@MainActor` 实例属性，每次 `beginSelectionSession()` 写入新 UUID |
| `windowSnapshotTask: Task<Void, Never>?` | 嵌套窗口快照任务句柄，用于 `endSelectionSession()` 时取消 |
| `beginSelectionSession()` | 先 `windowSnapshotTask?.cancel()` + `windowSnapshotTask = nil`，再生成新 UUID 并写入 `selectionSessionID`，返回该 UUID |
| `endSelectionSession()` | 同上 cancel 操作 + `selectionSessionID = nil`。被 `selectionWindowDidCancel`、`scheduleSelectionCleanup` 调用 |
| `isCurrentSelectionSession(_ id: UUID) -> Bool` | 比较实参与 `selectionSessionID` 是否相等，所有可能在 `await` 之后写入 self 状态的闭包都用它做前置 guard |

**典型守卫位置**（伪代码，对照 `ScreenshotService.swift:474-548`）：

```swift
let sessionID = beginSelectionSession()
Task {
    let displaySnapshots = try await prepareFrozenDisplaySnapshotsWithScreenCaptureKit()
    guard isCurrentSelectionSession(sessionID) else { return }     // ① 进 main 写状态前
    await MainActor.run {
        guard isCurrentSelectionSession(sessionID) else { return } // ② 重入兜底
        self.frozenDisplaySnapshots = displaySnapshots
        ...
    }
    windowSnapshotTask = Task {
        guard isCurrentSelectionSession(sessionID) else { return } // ③ 嵌套任务起点
        if overlayWindowIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard isCurrentSelectionSession(sessionID) else { return } // ④ sleep 后重检
            ...
        }
        let windowSnapshots = try await prepare...(excludingWindowIDs:)
        guard isCurrentSelectionSession(sessionID) else { return } // ⑤
        await MainActor.run {
            guard isCurrentSelectionSession(sessionID) else { return } // ⑥
            self.frozenWindowSnapshots = ...
        }
    }
}
```

每一处 `await` 之后回到 `@MainActor` 写状态前都要重新 guard，是这套机制的核心模式。



### 2.6 冻结快照的 ScreenCaptureKit 配置对照

两种冻结快照走不同的 `SCContentFilter` 策略，对理解 retina 输出尺寸和遮挡恢复至关重要：

| 维度 | `captureDisplaySnapshot` | `captureWindowSnapshot` |
|---|---|---|
| filter 类型 | `SCContentFilter(display: scDisplay, excludingWindows: [])` | `SCContentFilter(desktopIndependentWindow: window)` |
| 语义 | 整屏合成输出（含所有可见窗口叠加） | 单窗口独立内容（含被遮挡区域恢复） |
| 像素尺寸 | `screen.frame.size × screen.backingScaleFactor` | `filter.contentRect.size × filter.pointPixelScale` |
| `scalesToFit` | `false` | `false` |
| `captureResolution` | `.best` | `.best` |
| `showsCursor` | `false` | `false` |
| `sourceRect` | `CGRect(origin: .zero, size: screen.frame.size)` | 不设（整窗） |
| 输出 | `CGImage`（display 合成） | `CGImage`（窗口独立内容） |

**关键区别**：display snapshot 是"屏幕上看到什么就截什么"，window snapshot 是"这个窗口完整内容是什么（即使被遮挡）"。后者是 burst 方案的核心能力。

### 2.7 函数清单（本表列举调度核心函数共 49 项；源码实际声明约 56 个方法）

| 分组 | 函数 | 参数 | 备注 |
|---|---|---|---|
| **入口** | `captureScreenshot(trigger:)` | `.menuBar / .hotkey / .appIntent / .automation` | quick mode。 |
| | `captureAdvancedScreenshot(trigger:)` | `.menuBar / .hotkey / .appIntent / .automation` | advanced mode。 |
| | `captureOCRScreenshot(trigger:)` | `.menuBar / .hotkey / .appIntent / .automation` | ocr mode。 |
| | `captureFullScreen(trigger:)` | `.menuBar / .hotkey / .appIntent / .automation` | 直接抓全屏并集，不走选区。 |
| | `captureWindowUnderMouse(trigger:mode:)` | + `mode: .quick/.advanced/.ocr` | 不开选区窗口，直 hit-test。 |
| **调度** | `startSelectionFlow(overlayConfiguration:)` | `.screenshot / .ocr` | 选区主控。 |
| | `beginSelectionSession()` | — | 返回 UUID。 |
| | `endSelectionSession()` | — | 取消未完成的 windowSnapshotTask。 |
| | `isCurrentSelectionSession(_:)` | UUID | 防过期 UUID 写状态。 |
| | `scheduleSelectionCleanup(postCaptureFlowEnded:)` | Bool | 100 ms 后释放。 |
| **冻结快照** | `prepareFrozenDisplaySnapshotsWithScreenCaptureKit()` | — | **串行** for 屏。 |
| | `prepareFrozenWindowSnapshotsWithScreenCaptureKit(excludingWindowIDs:)` | — | **串行** for 窗。 |
| | `visibleWindowIDsByDisplay(excludingWindowIDs:)` | — | 通过 `CGWindowListCopyWindowInfo` 排序，每屏上限 `max(AppSettings.shared.frozenWindowLimitPerDisplay, 5)`（默认 5 为下界，用户可上调）。 |
| | `captureDisplaySnapshot(screen:scDisplay:excludedWindows:)` | — | 单屏 SCKit 抓帧。 |
| | `captureWindowSnapshot(window:applyBorder:)` | — | 单窗 SCKit 抓帧（独立窗模式）。 |
| | `frozenCapture(for:)` | `rect: CGRect` | 在已有 display snapshot 中裁切。 |
| | `applyFrozenBorderIfNeeded(to:scale:)` | — | （存在但本次未读完整体，与 WindowCaptureCoordinator 的 addBorderIfNeeded 平行）。 |
| **选区回调** | `selectionWindow(_:didSelectRect:)` | rect | drag 完成。 |
| | `selectionWindow(_:didSelectWindow:)` | hit | window click 完成。 |
| | `selectionWindowDidCancel(_:)` | — | ESC / 右键 / 取消。 |
| **执行截屏（非冻结路径）** | `performCapture(rect:captureType:trigger:excludeWindowIDs:)` | quick | 调 `captureWithScreenCaptureKit`。 |
| | `performAdvancedCapture(rect:captureType:trigger:excludeWindowIDs:)` | advanced | |
| | `performOCRCapture(rect:captureType:trigger:excludeWindowIDs:)` | ocr | |
| | `performWindowCapture(hitResult:captureType:trigger:excludeWindowIDs:)` | quick | 调 `WindowCaptureCoordinator.captureWindow`。 |
| | `performAdvancedWindowCapture(hitResult:captureType:trigger:excludeWindowIDs:)` | advanced | |
| | `performOCRWindowCapture(hitResult:captureType:trigger:excludeWindowIDs:)` | ocr | |
| | `captureWithScreenCaptureKit(rect:excludeWindowIDs:)` | wrapper | 转给 `captureScreenRegion`。 |
| | `captureScreenRegion(rect:excludeWindowIDs:)` | — | 选区域跨屏的 SCKit 真实抓帧。 |
| **结果处理** | `handleSuccessfulCapture(cgImage:selectionRect:captureType:trigger:appBundleID:appName:)` | quick | 复制剪贴板 + 入库 + 落盘。 |
| | `handleAdvancedCapture(cgImage:selectionRect:captureType:trigger:appBundleID:appName:)` | advanced | 打开 `ImageEditingWindow`。 |
| | `performOCRFrozenCapture(cgImage:selectionRect:captureType:trigger:appBundleID:appName:)` | ocr | Vision OCR + 写剪贴板/入库。 |
| | `handleOCRResult(_:)` | text | 处理 OCR 文本（去空白、多行处理、写剪贴板）。 |
| | `handleEditedImage(editedImage:selectionRect:...)` | — | advanced 编辑器返回后入库。 |
| **落盘** | `saveToDiskAsync(cgImage:pointSize:)` | — | `Task.detached(.utility)` 调 `saveToFile`。 |
| | `saveToFileAndGetPath(cgImage:pointSize:)` | — | 同步版本，从剪贴板路径返回 needs。 |
| | `saveToFile(cgImage:pointSize:imageFormat:sequence:folderPath:)`（`nonisolated static`） | — | **PNG/JPEG 编码 + 写盘**。这里是大头。 |
| | `writeAutomationFileAndPost(requestID:cgImage:pointSize:)` / `writeAutomationFile` | — | AppIntent 专用写临时文件。 |
| **其他** | `copyToClipboard(image:cgImage:pointSize:allowSaving:)` | — | NSPasteboard 写图，可选写文件 URL。 |
| | `restorePreviousAppFocus()` | — | 把焦点还给 capture 前的前台 app。 |
| | `capturePreviousApp()` | — | 选区出现前记住前台 app。 |
| | `showSuccessNotification(filePath:)` | — | Dynamic Island。 |
| | `showErrorAlert(_:) / showErrorNotification(error:)` | — | NSAlert。 |
| | `resolvedAppInfo(appBundleID:appName:)` | — | 兜底应用信息。 |
| | `libraryTrigger(from:)` | — | `CaptureTrigger` → `CaptureItemTrigger`。 |
| | `beginAutomationRequest(requestID:returnType:)` | — | AppIntent 注册。 |
| | `postAutomationResult(requestID:filePath:ocrText:error:)` | — | AppIntent 完成回调。 |
| | `completeAutomationIfNeeded(filePath:ocrText:error:)` | — | 取消/失败兜底。 |
| **辅助函数** | `detectFrontmostApp()` | — | 由 bundleID 判定 `AppCategory`。 |
| | `sanitizedAppString(_:)` | `String?` | `resolvedAppInfo` 内部依赖。 |
| | `makePNGClipboardData(cgImage:pointSize:)` | — | `copyToClipboard` 内部生成 PNG Data。 |
| | `makeMarkdownImageReference(filePath:)` | — | Markdown 模式生成 `![...]` 引用。 |
| | `makeMarkdownCodeBlock(text:)` / `longestBacktickRun(in:)` | — | OCR markdown fenced code block 输出。 |
| | `showOCRFeedback(style:key:fallback:)` | — | OCR 成功/失败 Dynamic Island 反馈。 |
| | `deinit` | — | 移除 NotificationCenter 观察者。 |

---

## 3. 截屏底层：WindowCaptureCoordinator

`PastScreen/Services/WindowCaptureCoordinator.swift`（396 行）。`@MainActor final class WindowCaptureCoordinator`。

### 3.1 命中测试

| 函数 | 用途 |
|---|---|
| `hitTestFrontmostWindow(quartzPoint:excludingPIDs:excludingWindowIDs:skipSelfWindows:) throws` | 用 `CGWindowListCopyWindowInfo` 找出包含给定点、最前面、过滤掉自身/系统 overlay 的窗口（`selfPID` 默认排除自身，layer 限定在 `normalWindow...popUpMenuWindow` 范围，同时跳过全屏覆盖窗口）。Chromium/Electron 子窗口提升到完全包含的同 PID 父窗口。 |
| `hitTestFrontmostWindowAtMouse(...)` | 上者的 mouse-location 便捷封装。 |

返回 `WindowHitTestResult: Sendable`。这是选区窗口 hover 高亮和 `captureWindowUnderMouse` 共用的入口。

**错误类型**：`WindowCaptureError`（`WindowCaptureCoordinator.swift:57-88`）含 6 个 case：`mouseLocationUnavailable`、`noWindowAtPoint`、`shareableWindowNotFound(CGWindowID)`、`invalidWindowSize`、`streamError(SCStreamError)`、`generic(String)`，并针对 `userDeclined` / `systemStoppedStream` 做本地化映射。

### 3.2 辅助类型

| 类型 | 位置 | 用途 |
|---|---|---|
| `WindowCandidate`（private struct） | line 95-103 | 命中测试内部候选记录：`windowID`、`quartzBounds`、`ownerPID`、`ownerName`、`layer`、计算属性 `area` |
| `QuartzSpace`（private struct） | line 105-116 | Quartz ↔ AppKit 坐标转换工具：`quartzPoint(fromAppKitGlobal:)` 和 `appKitRect(fromQuartz:)`。macOS 的 Quartz 坐标系原点在左上角，AppKit 在左下角，所有命中测试和 frame 转换都经过这里 |
| `selfPID: pid_t` | line 93 | `getpid()` 缓存，`skipSelfWindows: Bool = true` 时用于默认排除自身 PID 的窗口 |

### 3.3 单窗截屏

| 函数 | 用途 |
|---|---|
| `captureWindow(with:applyBorder:)` async throws | 给定 windowID，**重新跑** `SCShareableContent` 找 SCWindow，构造 `desktopIndependentWindow` filter 和 `SCStreamConfiguration`（按 `filter.pointPixelScale` 设置 `config.width/height`，`resolution = .best`，`scalesToFit = false`），调 `SCScreenshotManager.captureImage`，可选加边框。 |
| `captureWindow(using:applyBorder:)` async throws | hitResult 便捷封装，转给上者。 |
| `addBorderIfNeeded(to:borderPoints:cornerRadiusPoints:scale:color:)` | CGContext 重绘加边，返回 `BorderRenderResult?`（构造失败时可能为 `nil`）。 |

返回 `WindowCaptureInfo: Sendable`（`SendableCGImage` + `windowFrame: CGRect` + 应用元数据 `appBundleID/appName` + `paddingPoints: EdgeInsetValues`——`EdgeInsetValues` 是 `NSEdgeInsets` 的 Sendable 替身）。

**性能注意**：每次 `captureWindow` 都会单独 `await SCShareableContent.excludingDesktopWindows(...)` 一次。在 `prepareFrozenWindowSnapshotsWithScreenCaptureKit` 已经枚举过的情况下，这是重复枚举。

---

## 4. 选区窗口：SelectionWindow

`PastScreen/Views/SelectionWindow.swift`（449 行）。

### 4.1 多屏 overlay

`SelectionWindow: NSWindow`（**逻辑容器，自身不是视觉窗口**），内部维护 `overlayWindows: [OverlayWindow]`，**每个 NSScreen 一个 OverlayWindow**（`final class OverlayWindow: NSPanel`，`styleMask = [.borderless, .nonactivatingPanel]`，`isFloatingPanel = true`，`becomesKeyOnlyIfNeeded = true`，`hidesOnDeactivate = false`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`，`level = .screenSaver`，`isOpaque = false`，`backgroundColor = .clear`，`hasShadow = false`，`acceptsMouseMovedEvents = true`）。这些属性共同确保"不抢焦点 + 全屏 Space 兼容 + 透明 overlay"。

每个 overlay 内挂一个 `SelectionOverlayView`，构造参数名为 `backgroundImage: CGImage?`（数据源来自外部传入的 `frozenScreenshots: [CGDirectDisplayID: CGImage]`）。

`SelectionWindow` 对外还提供 `setOverlayAlpha(_:)`（给 `ScreenshotService` 调后台截图阶段透明化 overlay）和 `updateBackgroundSnapshots(_:)`（刷新冻结快照）。

### 4.2 SelectionOverlayView 行为

`clickThreshold`（screenshot = **10**，ocr = **2**）与 `minSelectionSize`（screenshot = **10**，ocr = **2**）来自 `Configuration` 结构。`SelectionOverlayView` 有 `NSTrackingArea` 三件套 + `acceptsFirstMouse = true` + `shouldDelayWindowOrdering = false` + `acceptsFirstResponder = true`，确保"非前台 App 一次点击响应 + mouseMoved 持续触发"。

| 事件 | 行为 |
|---|---|
| `mouseMoved` | `guard !isDragging` 短路；`hoverWindowHit = resolveWindowHit()`（内部调 `WindowCaptureCoordinator.hitTestFrontmostWindowAtMouse` 并设置 `highlightRect`），同时把 `pendingWindowHit = hoverWindowHit`，然后 `needsDisplay = true`。 |
| `mouseDown` | `startPoint = convert(...)`；`endPoint = startPoint`；`isDragging = true`；`pendingWindowHit = hoverWindowHit ?? resolveWindowHit()`（hover 缓存为 `nil` 时兜底再测一次）；`needsDisplay = true`。 |
| `mouseDragged` | 实时更新 `endPoint`；若 `max(deltaX, deltaY) > configuration.clickThreshold` 则同时清掉 `pendingWindowHit / hoverWindowHit / highlightRect`，进入纯框选模式。 |
| `mouseUp` | (1) 若 `!isDragging` 或起止点缺失 → `onCancel`；(2) 计算 `hasDragged = max(Δx, Δy) > clickThreshold`；(3) `!hasDragged && pendingWindowHit != nil` → `onWindowSelect`；(4) rect 宽/高都 > `minSelectionSize` → `onComplete(rect)`，否则 → `onCancel`。**callback 通过 `Task { @MainActor [weak self] in }` 转发**，避免事件分发过程中 view/window 已被释放的崩溃。 |
| `rightMouseDown` | 清状态后 `onCancel()`。 |

**ESC 取消**属于 `SelectionWindow` 层，不在 `SelectionOverlayView` 内部。共三条路径：
1. `SelectionWindow.keyDown`（overlay 为 key window 时）→ `delegate.selectionWindowDidCancel`。
2. `escapeKeyMonitor`（`SelectionWindow` 实例属性）—— 在 `show()` 内安装的全局 `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`，overlay 不是 key window 时也能生效；`hide()` 时卸载。
3. `OverlayWindow.keyDown` 当前仅透传给父类。

### 4.3 绘制

`draw(_:)` 每帧重绘（受 `needsDisplay = true` 驱动）：
1. 画 `backgroundImage`（冻结快照）
2. `NSColor.black.withAlphaComponent(configuration.overlayOpacity)` 半透明蒙层（默认 `overlayOpacity = 0.2`）
3. 在 **hole rect** 里再画一次 `backgroundImage`（不蒙层）
4. `NSColor.systemBlue`，`lineWidth = 2`，描边

**hole rect 来源优先级**：若 `startPoint + endPoint` 有位移（正在拖动）→ 取实时选区 rect；否则 → 取 `highlightRect`（hover 命中窗口的 view 坐标矩形）。均无则跳过描边。

```
冻结快照 → 黑色 0.2 蒙层 → 在 hole rect 里重画快照 → systemBlue 线宽 2 描边
```

### 4.4 与 ScreenshotService 的接口

```swift
protocol SelectionWindowDelegate: AnyObject {
    func selectionWindow(_ window: SelectionWindow, didSelectRect rect: CGRect)
    func selectionWindow(_ window: SelectionWindow, didSelectWindow windowResult: WindowHitTestResult)
    func selectionWindowDidCancel(_ window: SelectionWindow)
}
```

`getOverlayWindowIDs() -> [CGWindowID]` 给 ScreenshotService 用于排除自身窗口（避免 overlay 被截进背景）。

### 4.5 补充细节

**`viewDidMoveToWindow()` 重置**：`SelectionOverlayView` 在挂上 window 时重置 `hoverWindowHit / pendingWindowHit / highlightRect / didReceiveMouseMove` 等状态并 `needsDisplay = true`，防止跨次复用 SelectionWindow 时残留旧值。

**`emitSelection` 坐标转换**：选区 rect 通过 `convert(rect, to: nil)` → `window.convertToScreen(rectInWindow)` 两步从 view 坐标转为屏幕全局坐标后才发给 delegate。这保证了多屏场景下 rect 的绝对位置正确。

**`resolveWindowHit` 排除逻辑**：调用 `WindowCaptureCoordinator.shared.hitTestFrontmostWindowAtMouse(excludingWindowIDs: Set([CGWindowID(window.windowNumber)]))` 时只排除"当前 view 所在的那一块 overlay"。多屏场景下其他屏的 overlay 仍依赖 `getOverlayWindowIDs()` 在更上层（ScreenshotService 的 `prepareFrozenWindowSnapshotsWithScreenCaptureKit`）排除。

**`show()` / `hide()` 生命周期**：`show()` 内部用 `orderFrontRegardless()` 而非 `makeKeyAndOrderFront`，刻意避免抢焦点；`hide()` 会一次性 `orderOut(nil)` 并把 `ignoresMouseEvents` 改回 `true`。

---

## 5. 入库与落盘

### 5.1 CaptureLibrary

`PastScreen/Services/CaptureLibrary.swift`（759 行）。`@MainActor final class CaptureLibrary`。

入口：

```swift
@discardableResult
func addCapture(
    id: UUID = UUID(),
    cgImage: CGImage,
    pointSize: CGSize,
    captureType: CaptureItemCaptureType,
    captureMode: CaptureItemCaptureMode,
    trigger: CaptureItemTrigger,
    appBundleID: String?,
    appName: String?,
    appPID: Int?,
    externalFilePath: String?,
    ocrText: String? = nil,
    ocrLangs: [String] = []
) -> UUID?
```

行为：
1. 读取 `AppSettings.shared` 上的 `captureLibraryEnabled` / `captureLibraryStorePreviews` / `captureLibraryAutoOCR` / `ocrRecognitionLanguages`
2. 构造 `CaptureLibraryAddJob(cgImage: SendableCGImage(cgImage), ...)`（`SendableCGImage` 跨 actor 持有 cgImage 强引用，直到 worker 处理完才释放）
3. `enqueue(priority: .utility) { worker in try await worker.addCapture(job: job) }`
4. 立刻返回 UUID（**不等入库完成**），但当 backlog（默认 `maxPendingJobs = 8`）已满时返回 `nil` 并丢弃任务（打 `logWarning`）

下游 `CaptureLibraryWorker`（单例 actor，因此所有 job 串行执行）：
- **thumbnail 写盘**（必写，`fileStore.writeThumbnail`）
- **preview 写盘**（仅当 `storePreview == true`，`fileStore.writePreview`）
- **SQLite 主表 + FTS5 全文索引**同时写入（`database.insertCapture(item, ftsText:)`，其中 `ftsText` 由 `CaptureLibraryFTS.makeText(appName, externalFilePath, tagsCache, note, ocrText)` 生成）
- `notifyChanged()` 通知 UI（第一次，在 OCR 之前）
- 若 `autoOCR == true` 且原始 `ocrText` 为空，则**同步 await** `OCRService.recognizeText(...)` 并再次写库 + `notifyChanged()`（第二次）。由于 worker 是串行 actor，这条 OCR 会阻塞后续 add job。

**性能特点**：从主流程视角看，addCapture 是 fire-and-forget，~0 ms。`CaptureLibraryWorker` 串行模型意味着自动 OCR 会延长当前 job 的 actor 占用，但 addCapture 入口本身不阻塞。

### 5.1.1 并发控制与 enqueue 实现

`CaptureLibrary` 通过两组计数器控制 backlog：

| 计数器 | 上限 | 用途 |
|---|---|---|
| `pendingJobs` / `maxPendingJobs = 8` | 添加类任务（`addCapture`、`updateExternalFilePath` 等） |
| `pendingIndexJobs` / `maxPendingIndexJobs = 2` | 索引类任务（`requestOCR`、`reindex` 等） |

`enqueue(priority:operation:)` 实现：
1. `pendingJobs >= maxPendingJobs` → 返回 `false`，调用方得到 `nil`，任务被丢弃并打 `logWarning`
2. `pendingJobs += 1`
3. `Task.detached(priority:) { await operation(self.worker) }`——`Task.detached` 切断 `@MainActor` 继承，让 worker actor 在后台执行
4. 完成后 `Task { @MainActor in self?.releaseJobSlot() }`——计数器在主 actor 上维护，保证线程安全

**`CaptureLibraryWorker` 是单例 actor**：`CaptureLibrary` 持有 `private let worker = CaptureLibraryWorker()`，所有入库任务在同一 actor 上**串行**执行。这意味着：
- 自动 OCR 会阻塞后续 add job（OCR 耗时 200–2000 ms 不等）
- 但不会阻塞主线程（因为 `enqueue` 本身是 fire-and-forget）
- 8 个 pending slot 是"允许排队的最大深度"，不是并发度

### 5.1.2 FTS 全文索引构成

`CaptureLibraryFTS.makeText(appName, externalFilePath, tagsCache, note, ocrText)` 生成的 FTS5 索引文本包含：
- 应用名（如 "Microsoft Edge"）
- 外部文件路径（如 "/Users/.../Screen-42.png"）
- 标签缓存（用户手动打的标签）
- 笔记（用户手动添加的备注）
- OCR 识别文本

这意味着用户可以通过应用名、文件名、标签、笔记、OCR 文本中的任意关键词搜索截图。

### 5.2 落盘

`saveToDiskAsync(cgImage:pointSize:) async -> String?`：

```swift
let imageFormat = AppSettings.shared.imageFormat
var seq = AppSettings.shared.screenshotSequence
AppSettings.shared.ensureFolderExists()
let folderPath = AppSettings.shared.saveFolderPath
let sendableImage = SendableCGImage(cgImage)

let (savedPath, finalSeq) = await Task.detached(priority: .utility) {
    let savedPath = ScreenshotService.saveToFile(...)
    return (savedPath, seq)
}.value

AppSettings.shared.screenshotSequence = finalSeq
return savedPath
```

`saveToFile(cgImage:pointSize:imageFormat:sequence:folderPath:)`（`private nonisolated static`）：

1. `NSBitmapImageRep(cgImage: cgImage)` ← **alloc 一份 RGBA8 副本**
2. `bitmapImage.size = pointSize`（设置点尺寸 metadata）
3. `bitmapImage.representation(using: .png 或 .jpeg, properties: [:])` ← **PNG/JPEG 软件编码**，retina 全屏图 ~150–300 ms
4. 文件名递增：`Screen-<seq>.<png|jpg>`（扩展名跟随 `imageFormat`），**`while fileManager.fileExists` 循环**；结束后 `sequence = 已用 seq + 1`
5. 写盘 `data.write(to:)`
6. 失败 fallback 到 `NSTemporaryDirectory()`；再失败则返回 `nil`

另存在同步版本 `saveToFileAndGetPath(cgImage:pointSize:) -> String?`（`@MainActor`），用于 `copyToClipboard` 等不能 await 的场景，内部调用同一个 `saveToFile` 实现。

**这是整条流程里 wall-clock 最大的单一开销**。

**`saveToDiskAsync` 的 actor 隔离说明**：函数本身是 `@MainActor`（因类的隔离），但 I/O 通过 `Task.detached(priority: .utility)` 显式脱离 MainActor，是"正确的 MainActor offload 范式"——不会阻塞 UI。`await .value` 等待结果时 MainActor 可以处理其他事件。

---

## 6. 性能现状汇总（按 wall-clock 贡献排序）

| 节点 | 估计耗时 | 阻塞用户感知吗？ | 备注 |
|---|---|---|---|
| `saveToFile` PNG 编码 | **150–300 ms** | 不（detached），但用户得等通知 | NSBitmapImageRep + PNG，单线程 |
| `prepareFrozenDisplaySnapshotsWithScreenCaptureKit`（多屏串行） | 60–200 ms | **是**（决定选区出现时间） | 单屏 ~60–100 ms，2 屏 ~150 ms |
| `prepareFrozenWindowSnapshotsWithScreenCaptureKit`（多窗串行） | 150–500 ms | 部分（用户在 burst 完成前选窗会走慢路径） | 5 窗串行 ~150–250 ms（每窗约 30 ms 串行 baseline；上限为 `max(AppSettings.frozenWindowLimitPerDisplay, 5)`，默认 5 为下界） |
| `selectionWindow(_:didSelectRect:)` 内 `Task.sleep(150 ms)` | **150 ms 固定** | **是** | 等 overlay 视觉消失，对用户是「松开鼠标→看到结果」的直接延迟 |
| `selectionWindow(_:didSelectWindow:)` 内 `Task.sleep(150 ms)` | **150 ms 固定** | **是** | 同上 |
| `AppDelegate.performXxxCapture` 里的 `Task.sleep(50 ms)` | 50 ms 固定 | 是 | 等权限 alert 关闭，多数情况不需要 |
| `scheduleSelectionCleanup` 的 `Task.sleep(100 ms)` | 100 ms 固定 | 否（清理） | |
| `prepareFrozenWindowSnapshots` 内 50 ms `Task.sleep` 兜底 | 50 ms 条件触发 | 部分 | overlayWindowIDs.isEmpty 时才触发 |
| `captureScreenRegion`（frozen 未命中时的退路） | 100–250 ms | **是** | 选区不命中冻结快照时重新走 SCKit 抓帧 |
| `captureWindow(with:)` 重复 `SCShareableContent` 调用 | ~10–30 ms | 间接 | 每个 hit 路径都重新跑一次枚举 |
| `captureScreenRegion` 重复 `SCShareableContent.current` | ~10–30 ms | 间接 | 选区不命中 frozen 时多一次 |
| `Task.sleep(150 ms)` × 2（rect/window 任一) | — | — | 这俩是同一个，不会叠加 |
| `frozenCapture(for:rect)` 裁切 | <5 ms | 否 | CG `cropping` 是 lazy |
| `copyToClipboard` PNG 写剪贴板 | 50–150 ms | 是（同步写） | 同样走 NSBitmapImageRep |

**最坏路径累计**（选区截图 + 多屏 + 落盘）：

```
50 (Task.sleep) + 200 (display snapshot) + 用户操作时间 +
150 (Task.sleep) + 200 (region capture if not frozen) +
100 (clipboard PNG) + 200 (落盘 PNG, 用户看通知前)
≈ 用户操作前 250 ms + 操作后 ~650 ms
```

最优路径（命中 frozen + 单屏 + 单窗 + 已落盘）：

```
50 + 80 (display snapshot) + 用户操作 + 150 + 0 (frozen hit) + 50 (clipboard)
≈ 操作前 130 ms + 操作后 ~200 ms
```

---

## 7. 已识别的优化点（仅记录现状，不在本文档里设计实现）

按 ROI 排序，每条都需要后续在专门 spec 里展开：

1. **PNG → HEIC 默认 + `CGImageDestination` 直出**：节省 100–250 ms，文件减半。当前 `saveToFile` 走 `NSBitmapImageRep.representation(using: .png)` 是软件编码，`CGImageDestination` + HEIC UTType 可走硬件编码。
2. **Window snapshot 串行 → 并发 burst（含可见性过滤）**：4–13 窗口实测可从 250–500 ms 压到 80–150 ms。已有 `scripts/sck_burst_probe/` 验证。
3. **Display snapshot 串行 → 并发**：多屏场景节省 50–100 ms。`withTaskGroup` 即可。
4. **150 ms / 50 ms 硬等待 → vsync 等待或事件驱动**：~150 ms 可压到 ~16 ms（一帧）。需要确认 macOS 26 上 `CADisplayLink`/`CVDisplayLink` 的最佳路径。
5. **`SCShareableContent` 复用**：在一次 selection flow 内只调一次，结果通过 session 缓存给所有 capture 路径。节省 10–30 ms × 多次。
6. **clipboard PNG 写入也走 HEIC / 直出**：节省 50–150 ms。
7. **文件名 sequence 改原子计数器 + 时间戳兜底**：高频用户场景节省 O(n) 扫盘。

每一项都和 Swift 6 迁移无强耦合（迁移已完成），可以独立 spec 推进。

---

## 8. 验证手段（已就位）

- `scripts/sck_burst_probe/` — 独立 Swift 命令行工具，验证 SCScreenshotManager 在 macOS 26 上的：
  - 单次延迟分布（avg/p50/p90/p99）
  - 并发 burst wall-clock
  - 可见性过滤效果（z-order + 矩形减法）
  - 1× / 2× pixel scale 对比
  - 紫点指示器行为（人眼观察）

- 实测结论（macOS 26.5 / M 系 mac）：
  - 单窗口冷启 ~90 ms，热启 ~31 ms
  - 系统并发上限约 2–3 并发，再多排队
  - 6 个真实可见窗口（含视频）warm wall-clock ≈ 140 ms
  - 13 窗口 warm wall-clock ≈ 275 ms，外推 30 窗口 ≈ 580 ms
  - 紫点 ~2 秒衰减消失，无 active streams 常驻条目
  - 1× scale 反而比 2× 略慢（系统先抓 2× 再下采样）

---

## 9. 不在范围内的事

- 编辑器（`ImageEditingWindow`）的渲染性能与本流程无关，advanced 模式之后由编辑器自管。
- OCR 识别耗时（Vision）是独立成本，不在本次截图流水线优化范围。
- `CaptureLibrary` 入库到 SQLite 的 worker 内部流程在 `swift6-concurrency-migration` 已优化，本次不动。
- 通知渲染（Dynamic Island）耗时与本流程无关。
