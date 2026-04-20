---
inclusion: auto
---

# PastScreen Swift 6 并发架构

本文档描述 PastScreen 作为 Swift 6 严格并发应用的完整隔离域架构，以及每种 Swift 6 编译错误的具体解决方式。

## 一、隔离域全景图

### @MainActor 隔离（UI 层 — 主线程串行）

所有持有 `@Published` 属性或驱动 UI 的单例/类：

| 类 | 文件 | 职责 |
|----|------|------|
| `AppDelegate` | PastScreenApp.swift | 应用生命周期、菜单栏、权限请求 |
| `AppSettings` | Models/AppSettings.swift | 全局设置（~30 个 @Published 属性） |
| `ScreenshotService` | Services/ScreenshotService.swift | 截图核心流程、选区窗口、剪贴板 |
| `CaptureLibrary` | Services/CaptureLibrary.swift | 素材库入口、任务队列调度 |
| `HotKeyManager` | Services/HotKeyManager.swift | 全局热键监听 |
| `PermissionManager` | Services/PermissionManager.swift | 权限状态管理 |
| `WindowCaptureCoordinator` | Services/WindowCaptureCoordinator.swift | 窗口捕获（ScreenCaptureKit） |
| `LaunchAtLoginManager` | Services/LaunchAtLoginManager.swift | 开机启动 |
| `ScreenshotIntentBridge` | Services/ScreenshotIntentBridge.swift | AppIntents 桥接 |
| `CaptureLibraryCleanupService` | Services/CaptureLibraryCleanupService.swift | 素材库自动清理 |
| `CaptureLibraryOCRReindexService` | Services/CaptureLibraryOCRReindexService.swift | OCR 重建索引 |
| `OnboardingManager` | Views/OnboardingView.swift | 引导流程 |
| `TutorialManager` | Views/TutorialView.swift | 教程窗口 |
| `DynamicIslandManager` | Views/DynamicIslandView.swift | 菜单栏状态提示 |
| `CustomNotificationManager` | Views/CustomNotificationView.swift | 自定义通知 |
| `CaptureLibraryManager` | Views/CaptureLibraryView.swift | 素材库窗口管理 |
| `CaptureLibraryViewModel` | Views/CaptureLibraryView.swift | 素材库视图模型 |
| `CaptureLibraryMenuModel` | Views/MenuBarContentView.swift | 菜单栏历史列表 |
| `CaptureLibrarySettingsModel` | Views/SettingsView.swift | 设置页素材库模型 |

### Actor 隔离（后台串行 — 各自独立执行器）

| Actor | 文件 | 职责 |
|-------|------|------|
| `CaptureLibraryWorker` | Services/CaptureLibrary.swift | 素材库后台写入（文件 I/O + 数据库） |
| `CaptureLibraryDatabase` | Services/CaptureLibrary/Database/ | SQLite 数据库操作 |
| `CaptureLibrarySemanticSearchService` | Services/CaptureLibrary/ | 语义搜索（NLEmbedding） |

### nonisolated（无隔离 — 纯函数/纯值）

| 类型 | 文件 | 说明 |
|------|------|------|
| `OCRService` (struct) | Services/OCRService.swift | 纯静态方法，通过 DispatchQueue.global 做后台 OCR |
| `CaptureLibraryFileStore` (struct, Sendable) | Services/CaptureLibrary/ | 文件路径计算、缩略图写入 |
| `CaptureLibraryFTS` (enum) | Services/CaptureLibrary/ | FTS 文本构建、查询构建 |
| `CaptureLibraryTagNormalizer` (enum) | Services/CaptureLibrary/ | 标签规范化 |
| `CaptureLibrarySearchSyntaxParser` (enum) | Services/CaptureLibrary/ | 搜索语法解析 |
| `Logger` (struct) | Utils/Logger.swift | 日志输出（所有方法 nonisolated） |
| `AppSettings.normalizeOCRRecognitionLanguages` | Models/AppSettings.swift | 纯函数，nonisolated static |

### SwiftUI View（隐式 @MainActor）

所有 SwiftUI `View` 结构体自动继承 `@MainActor`：
`MenuBarContentView`, `CaptureLibraryView`, `SettingsView`, `OnboardingView`, `TutorialView`, `ImageEditingView`, `SelectionOverlayView` 等。

## 二、Sendable 值类型清单

### 模型层（CaptureLibraryModels.swift）
`CaptureItem`, `CaptureLibraryAppGroup`, `CaptureLibraryTagGroup`, `CaptureLibraryQuery`, `CaptureLibraryStats`, `CaptureLibraryCleanupPolicy`, `CaptureLibraryPreviewCandidate`, `CaptureLibraryOCRReindexCandidate`, `CaptureItemCaptureType`, `CaptureItemCaptureMode`, `CaptureItemTrigger`, `CaptureLibrarySort`

### 设置层（AppSettings.swift）
`HotKey`, `AppOverride`, `RGBAColor`, `ClipboardFormat`, `CaptureClipboardFormat`, `OCRClipboardFormat`, `AppLanguage`

### 服务层
`PermissionType`, `PermissionStatus`, `OCRServiceError`, `WindowHitTestResult`, `EdgeInsetValues`, `WindowCaptureInfo`, `WindowCaptureError`, `AppCategory`, `CaptureTrigger`, `CaptureLibraryFileStore`, `OCRLanguageOption`

### 视图层
`DrawingTool`, `DynamicIslandManager.Style`

### ScreenshotService 内部
`FrozenWindowSnapshot`, `AutomationRequest`

### @unchecked Sendable（需 SAFETY 注释）
| 类型 | 文件 | 理由 |
|------|------|------|
| `SendableCGImage` | CaptureLibraryModels.swift | CGImage 是不可变 CF 类型，线程安全 |
| `SwizzledBundle` | Localization.swift | Bundle 线程安全，只读 activeLanguageBundle |

## 三、跨隔离域边界与解决方式

### 3.1 @MainActor → 后台（Task.detached 切断继承）

用于 CPU 密集或 I/O 操作，需要离开主线程：

| 调用点 | 文件 | 捕获的 Sendable 值 |
|--------|------|--------------------|
| `CaptureLibrary.enqueue()` | CaptureLibrary.swift | operation: @Sendable 闭包 |
| `CaptureLibrary.enqueueIndexing()` | CaptureLibrary.swift | operation: @Sendable 闭包 |
| `ScreenshotService.writeAutomationFileAndPost()` | ScreenshotService.swift | SendableCGImage, CGSize, UUID, String |
| `ScreenshotService.saveToDiskAsync()` | ScreenshotService.swift | SendableCGImage, CGSize, String, Int |
| `CaptureLibraryOCRReindexService.schedule()` | CaptureLibraryOCRReindexService.swift | String, [String] |
| `CaptureLibrarySemanticSearchService.scheduleEmbeddingWrites()` | CaptureLibrarySemanticSearchService.swift | [(UUID, Data, String)], String, Int |
| `CaptureLibraryView` 图片加载（×3） | CaptureLibraryView.swift | URL path (String) |

关键模式：在 `Task.detached` 之前，将非 Sendable 值转换为 Sendable：
```swift
let sendableImage = SendableCGImage(cgImage)  // 包装 CGImage
let modelName = config.modelName              // 提取 Sendable 字段
Task.detached { use(sendableImage, modelName) }
```

### 3.2 后台 → @MainActor（Task { @MainActor in }）

后台任务完成后回到主线程更新 UI：

| 场景 | 模式 |
|------|------|
| Task.detached 完成后释放 job slot | `Task { @MainActor [weak self] in self?.releaseJobSlot() }` |
| Actor 内部通知 UI 刷新 | `Task { @MainActor in NotificationCenter.default.post(...) }` |
| Combine sink 接收值后更新状态 | `Task { @MainActor [weak self] in self?.handleChange(value) }` |
| Timer 回调触发 UI 操作 | `Task { @MainActor [weak self] in self?.dismiss() }` |
| 系统回调（UNUserNotificationCenter 等） | `Task { @MainActor in self.checkPermission() }` |

### 3.3 Apple 框架类型跨域（@preconcurrency import）

| import | 文件 | 抑制的类型 |
|--------|------|-----------|
| `@preconcurrency import AppKit` | HotKeyManager, ScreenshotService, SelectionWindow, CaptureLibraryView, ImageEditingWindow, SettingsView | NSEvent, NSImage, NSBitmapImageRep |
| `@preconcurrency import ScreenCaptureKit` | WindowCaptureCoordinator, ScreenshotService, OnboardingView | SCWindow, SCDisplay, SCContentFilter |
| `@preconcurrency import Vision` | OCRService | VNRecognizeTextRequest, VNImageRequestHandler |

### 3.4 SCWindow/SCRunningApplication 扁平化

ScreenCaptureKit 类型不是 Sendable，在捕获点立即提取值：

```
SCWindow + SCRunningApplication
  → WindowCaptureInfo (Sendable DTO)
    .image: SendableCGImage      ← CGImage 包装
    .windowFrame: CGRect         ← 值类型
    .appBundleID: String?        ← 从 SCRunningApplication 提取
    .appName: String?            ← 从 SCRunningApplication 提取
    .paddingPoints: EdgeInsetValues ← NSEdgeInsets 替代
```

同样，`FrozenWindowSnapshot` 存储 `appBundleID: String?` 和 `appName: String?` 而非 `SCRunningApplication`。

## 四、具体错误类型与解决方式对照表

### 错误 1："Main actor-isolated property 'X' can not be referenced from a nonisolated context"

| 场景 | 解决方式 | 示例 |
|------|----------|------|
| 默认参数表达式 | 移除默认值，由调用者传入 | `ImageEditingView.init(radialTools:)` |
| static 方法访问 .shared | 给方法加 @MainActor | `ImageEditingView.defaultTool()` |
| Combine sink 闭包 | `Task { @MainActor in }` 包装 | HotKeyManager 所有 sink |
| 系统回调（UNUserNotificationCenter 等） | `Task { @MainActor in }` 包装 | PermissionManager |
| deinit 调用隔离方法 | 内联安全操作，不调用隔离方法 | `HotKeyManager.deinit` |

### 错误 2："Non-sendable type 'X' in @Sendable closure / crossing isolation boundary"

| 场景 | 解决方式 | 示例 |
|------|----------|------|
| CGImage 跨域 | SendableCGImage 包装 | ScreenshotService.saveToDiskAsync |
| NSImage 从 Task.detached 返回 | @preconcurrency import AppKit | CaptureLibraryView 图片加载 |
| NLEmbedding 在 Config 中被捕获 | 提取 Sendable 字段（String, Int） | SemanticSearchService.scheduleEmbeddingWrites |
| SCWindow/SCRunningApplication | 扁平化为 WindowCaptureInfo DTO | WindowCaptureCoordinator.captureWindow |

### 错误 3："Conformance of 'NSEvent' to 'Sendable' is unavailable"

| 场景 | 解决方式 |
|------|----------|
| addGlobalMonitorForEvents 回调中 event 跨域 | @preconcurrency import AppKit |
| addLocalMonitorForEvents 回调 | @preconcurrency import AppKit |

### 错误 4："Call to main actor-isolated method in synchronous nonisolated context"

| 场景 | 解决方式 |
|------|----------|
| deinit 调用 stopMonitoring() | nonisolated deinit + 内联 NSEvent.removeMonitor |
| deinit 调用 NotificationCenter.removeObserver | 直接调用（removeObserver 是线程安全的） |

### 错误 5："Global variable is not concurrency-safe"

| 场景 | 解决方式 |
|------|----------|
| 运行时语言切换的 activeLanguageBundle | `nonisolated(unsafe)` + 注释说明 write-once-then-read 模式 |
| Bundle swizzle 的 _bundleSwizzleOnce | `let` 常量 + 闭包初始化（线程安全） |

## 五、NSLock → @MainActor 替代

CaptureLibrary 原有两个 NSLock（`pendingLock`, `indexingLock`）保护 job 计数器。迁移后：
- 移除所有 NSLock
- `acquireJobSlot()` / `releaseJobSlot()` 变为普通 @MainActor 方法
- `acquireIndexSlot()` / `releaseIndexSlot()` 同上
- @MainActor 保证串行访问，不需要锁

## 六、DispatchQueue → Swift 并发替代

| 原模式 | 新模式 | 适用场景 |
|--------|--------|----------|
| `DispatchQueue.main.async { }` | 直接调用 | 已在 @MainActor 上下文 |
| `DispatchQueue.main.async { }` | `Task { @MainActor in }` | 从非隔离上下文跳转 |
| `DispatchQueue.main.asyncAfter(deadline:)` | `Task { try? await Task.sleep(nanoseconds:); ... }` | 延迟执行 |
| `DispatchQueue.global().async { }` | `Task.detached(priority:) { }` | 后台 I/O（切断 @MainActor） |
| `saveQueue.async { }` (自定义队列) | `Task.detached(priority: .utility) { }` | 后台文件保存 |

## 七、Combine sink 隔离模式

所有 Combine `sink` 闭包统一使用 `Task { @MainActor in }` 模式：

```swift
observer = settings.$property.sink { [weak self] value in
    Task { @MainActor [weak self] in
        guard let self else { return }
        self.handleChange(value)
    }
}
```

涉及的文件：HotKeyManager（4 个 sink）、CaptureLibraryOCRReindexService（2 个 sink）。

`MainActor.assumeIsolated` 仅在 HotKeyManager 的 `addLocalMonitorForEvents` 回调中使用（该回调保证在主线程），附带 SAFETY 注释。

## 八、nonisolated 纯函数

不访问任何隔离状态的函数标记 `nonisolated`，可从任何隔离域自由调用：

- `AppSettings.normalizeOCRRecognitionLanguages(_:)` — 语言标签规范化
- `ScreenshotService.writeAutomationFile(...)` — 文件写入（从 Task.detached 调用）
- `ScreenshotService.saveToFile(...)` — 文件保存（从 Task.detached 调用）
- `CaptureLibraryFileStore` 所有方法 — 文件路径计算、目录创建、缩略图写入
- `CaptureLibraryFTS` 所有方法 — FTS 文本/查询构建
- `CaptureLibraryTagNormalizer.normalize(_:)` — 标签规范化
- `Logger` 所有方法 — 日志输出
- 全局便捷函数 `logDebug/logInfo/logSuccess/logWarning/logError`
