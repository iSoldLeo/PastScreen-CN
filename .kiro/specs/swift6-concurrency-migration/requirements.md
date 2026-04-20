# 需求文档：Swift 6 严格并发迁移

## 概述

本需求文档从设计文档推导而来，定义了将 PastScreen 从 Swift 5 并发模式迁移到 Swift 6 严格并发所需满足的所有验收标准。这是一次纯重构——零功能变更、零 UI 变更。

## 需求 1：Sendable 值类型一致性

### 用户故事
作为开发者，我需要所有跨隔离域传递的值类型和枚举都声明 `Sendable`，以便编译器能静态验证数据竞争安全性。

### 验收标准

- [ ] 1.1 所有 `CaptureLibraryModels.swift` 中的枚举（`CaptureItemCaptureType`、`CaptureItemCaptureMode`、`CaptureItemTrigger`）声明 `Sendable`
- [ ] 1.2 所有 `CaptureLibraryModels.swift` 中的结构体（`CaptureItem`、`CaptureLibraryAppGroup`、`CaptureLibraryTagGroup`、`CaptureLibraryQuery`、`CaptureLibraryStats`、`CaptureLibraryCleanupPolicy`、`CaptureLibraryPreviewCandidate`、`CaptureLibraryOCRReindexCandidate`）声明 `Sendable`
- [ ] 1.3 `AppSettings.swift` 中的枚举（`ClipboardFormat`、`CaptureClipboardFormat`、`OCRClipboardFormat`、`AppLanguage`）和结构体（`HotKey`、`AppOverride`、`RGBAColor`）声明 `Sendable`
- [ ] 1.4 `PermissionManager.swift` 中的枚举（`PermissionType`、`PermissionStatus`）声明 `Sendable`
- [ ] 1.5 `PastScreenApp.swift` 中的 `CaptureTrigger` 枚举声明 `Sendable`
- [ ] 1.6 `ScreenshotService.swift` 中的 `AppCategory` 枚举声明 `Sendable`
- [ ] 1.7 `WindowCaptureCoordinator.swift` 中的 `WindowHitTestResult` 结构体和 `WindowCaptureError` 枚举声明 `Sendable`
- [ ] 1.8 `OCRService.swift` 中的 `OCRServiceError` 枚举声明 `Sendable`
- [ ] 1.9 `CaptureLibraryFileStore` 结构体声明 `Sendable`
- [ ] 1.10 `CaptureLibrarySort` 枚举声明 `Sendable`
- [ ] 1.11 编译器在 `-strict-concurrency=complete` 下不对上述类型产生 Sendable 相关警告

## 需求 2：SendableCGImage 包装与 @unchecked Sendable 治理

### 用户故事
作为开发者，我需要一个安全的 `CGImage` 包装类型来跨隔离域传递图片数据，同时确保所有 `@unchecked Sendable` 使用都有线程安全论证。

### 验收标准

- [ ] 2.1 创建 `SendableCGImage` 结构体，声明 `@unchecked Sendable`，仅包含 `let image: CGImage`
- [ ] 2.2 `SendableCGImage` 附带 `// SAFETY:` 注释，说明 CGImage 的线程安全性论证
- [ ] 2.3 `CaptureLibraryAddJob` 中的 `cgImage` 字段类型从 `CGImage` 改为 `SendableCGImage`
- [ ] 2.4 `CaptureLibraryAddJob` 声明 `Sendable`
- [ ] 2.5 `ScreenshotService.frozenDisplaySnapshots` 字典值类型改为 `SendableCGImage`
- [ ] 2.6 `ScreenshotService.FrozenWindowSnapshot.image` 字段类型改为 `SendableCGImage`
- [ ] 2.7 项目中所有 `@unchecked Sendable` 类型都附带 `// SAFETY:` 注释

## 需求 3：@MainActor 单例隔离

### 用户故事
作为开发者，我需要所有全局单例类标注 `@MainActor`，以便编译器自动验证所有访问的隔离正确性，消除数据竞争。

### 验收标准

- [ ] 3.1 `AppSettings` 类标注 `@MainActor`
- [ ] 3.2 `AppSettings.normalizeOCRRecognitionLanguages(_:)` 保持 `nonisolated`（纯函数）
- [ ] 3.3 `HotKeyManager` 类标注 `@MainActor`
- [ ] 3.4 `PermissionManager` 类标注 `@MainActor`
- [ ] 3.5 `LaunchAtLoginManager` 类标注 `@MainActor`
- [ ] 3.6 `WindowCaptureCoordinator` 类标注 `@MainActor`
- [ ] 3.7 `ScreenshotService` 类标注 `@MainActor`
- [ ] 3.8 `CaptureLibrary` 类标注 `@MainActor`
- [ ] 3.9 `AppDelegate` 类标注 `@MainActor`（如果尚未隐式继承）
- [ ] 3.10 所有 `@MainActor` 类中不存在 `DispatchQueue.main.async { }` 调用（已在主线程，无需跳转）
- [ ] 3.11 所有 `DispatchQueue.main.asyncAfter` 替换为 `Task { try? await Task.sleep(nanoseconds:); ... }` 或在已有 async 上下文中直接 `Task.sleep`

## 需求 4：CaptureLibrary NSLock 移除

### 用户故事
作为开发者，我需要将 `CaptureLibrary` 的手动锁同步替换为 `@MainActor` 隔离，消除锁竞争风险并简化代码。

### 验收标准

- [ ] 4.1 `CaptureLibrary` 中不存在 `NSLock` 实例（`pendingLock`、`indexingLock`）
- [ ] 4.2 `acquireJobSlot()` / `releaseJobSlot()` 变为普通 `@MainActor` 方法（无锁）
- [ ] 4.3 `acquireIndexSlot()` / `releaseIndexSlot()` 变为普通 `@MainActor` 方法（无锁）
- [ ] 4.4 `enqueue()` 的 `operation` 参数标记 `@Sendable`
- [ ] 4.5 `enqueueIndexing()` 的 `operation` 参数标记 `@Sendable`
- [ ] 4.6 `Task.detached` 闭包不捕获任何 non-Sendable 值

## 需求 5：WindowCaptureResult 扁平化

### 用户故事
作为开发者，我需要将 `WindowCaptureResult` 替换为纯 `Sendable` 值 DTO，避免跨隔离域传递 `SCWindow` / `SCRunningApplication` 等非 Sendable 类型。

### 验收标准

- [ ] 5.1 创建 `EdgeInsetValues` 结构体（`Sendable`），替代 `NSEdgeInsets` 在跨隔离域场景的使用
- [ ] 5.2 创建 `WindowCaptureInfo` 结构体（`Sendable`），包含 `SendableCGImage`、`CGRect`、`String?`（bundleID/appName）、`EdgeInsetValues`
- [ ] 5.3 `WindowCaptureCoordinator.captureWindow()` 返回 `WindowCaptureInfo` 而非 `WindowCaptureResult`
- [ ] 5.4 `ScreenshotService.FrozenWindowSnapshot` 不包含 `SCRunningApplication`，改为存储扁平化的 `appBundleID: String?` 和 `appName: String?`
- [ ] 5.5 `ScreenshotService.FrozenWindowSnapshot` 声明 `Sendable`

## 需求 6：Actor 内部隔离修复

### 用户故事
作为开发者，我需要修复 actor 内部的隔离边界问题，确保 actor 与 `@MainActor` 之间的通信使用正确的模式。

### 验收标准

- [ ] 6.1 `CaptureLibraryWorker.notifyChanged()` 不使用 `DispatchQueue.main.async`
- [ ] 6.2 需要顺序保证的通知使用 `await MainActor.run { }`
- [ ] 6.3 允许延后的通知使用 `Task { @MainActor in }` 并附带注释说明
- [ ] 6.4 `CaptureLibraryOCRReindexService.runReindexLoop()` 中的 `DispatchQueue.main.async` 替换为 `Task { @MainActor in }`

## 需求 7：Combine sink 隔离修复

### 用户故事
作为开发者，我需要修复所有 Combine `sink` 闭包的隔离问题，确保从 `@MainActor` 属性接收值时正确跳转到主 actor。

### 验收标准

- [ ] 7.1 `HotKeyManager` 中所有 `sink` 闭包使用 `Task { @MainActor in }` 模式
- [ ] 7.2 `CaptureLibraryOCRReindexService` 中所有 `sink` 闭包使用 `Task { @MainActor in }` 模式
- [ ] 7.3 如果使用 `MainActor.assumeIsolated`，必须附带 `// SAFETY:` 注释说明为何安全
- [ ] 7.4 `PermissionManager` 中 `UNUserNotificationCenter` 回调使用 `Task { @MainActor in }` 替代 `DispatchQueue.main.async`

## 需求 8：@preconcurrency import 管理

### 用户故事
作为开发者，我需要对第三方框架的非 Sendable 类型使用 `@preconcurrency import` 进行临时抑制，并维护清单以便后续清理。

### 验收标准

- [ ] 8.1 需要 `@preconcurrency import` 的文件已添加（如 `ScreenCaptureKit`、`Vision` 等）
- [ ] 8.2 每个 `@preconcurrency import` 附带注释说明抑制原因
- [ ] 8.3 不使用 `@preconcurrency import` 来掩盖项目自身代码的 Sendable 问题

## 需求 9：编译与运行时验证

### 用户故事
作为开发者，我需要确认迁移后项目在 Swift 6 严格并发模式下干净编译，且运行时行为不变。

### 验收标准

- [ ] 9.1 项目在 Swift 5 语言模式 + `-strict-concurrency=complete` 下零警告编译
- [ ] 9.2 项目在 Swift 6 语言模式下零错误编译
- [ ] 9.3 所有现有测试（`CaptureLibraryDatabaseMigrationTests`、`CaptureLibrarySearchSyntaxParserTests`、`CaptureLibraryTagNormalizerTests`）通过
- [ ] 9.4 TSan (Thread Sanitizer) 运行时检查无数据竞争报告
- [ ] 9.5 核心流程手动验证通过：截图、OCR、素材库浏览、设置修改
- [ ] 9.6 零功能变更——用户可感知的行为与迁移前完全一致
