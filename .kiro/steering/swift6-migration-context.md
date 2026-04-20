---
inclusion: always
---

# PastScreen Swift 6 严格并发迁移 — 工作区上下文

## 项目概况

PastScreen 是一个 macOS 截图管理菜单栏应用（SwiftUI + AppKit）。当前正在进行 Swift 6 严格并发迁移（`-strict-concurrency=complete`），纯重构，零功能变更。

Spec 位于 `.kiro/specs/swift6-concurrency-migration/`，包含 requirements.md、design.md、tasks.md。

## 构建环境限制

- **没有 .xcodeproj / .xcworkspace 文件**（被 .gitignore 排除），无法使用 `xcodebuild`
- **只有 Command Line Tools**，没有完整 Xcode 安装，XCTest 不可用
- Swift 6.3 编译器可用，可以用 `swiftc -typecheck -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -strict-concurrency=complete` 做单文件或多文件类型检查
- 跨文件依赖（如 `AppSettings`、`DrawingTool`、`LaunchAtLoginManager`）会导致 "cannot find type in scope" 错误，这是正常的——不是 Sendable 问题
- 验证策略：对纯值类型文件做 `swiftc -typecheck`，对有复杂依赖的文件只做 grep/代码审查

## 迁移进度（截至 Task 3 完成）

### 已完成
- **Task 1**：所有值类型/枚举已添加 `Sendable`（14 个模型类型 + 7 个散布在各文件的枚举/结构体）
- **Task 2**：`SendableCGImage`（@unchecked Sendable 包装）已创建，`CaptureLibraryAddJob` 已改用 `SendableCGImage` 并标记 `Sendable`，`WindowCaptureCoordinator.captureWindow()` 已返回 `WindowCaptureInfo` DTO
- **Task 3**：Checkpoint 通过，所有 Sendable 类型在 `-strict-concurrency=complete` 下零警告编译

### 待做（Task 4 起）
- Task 4：`@MainActor` 标注到 `AppSettings`、`HotKeyManager`、`PermissionManager`、`LaunchAtLoginManager`、`WindowCaptureCoordinator`
- Task 5：`CaptureLibrary` 加 `@MainActor` + 移除 `NSLock`（`pendingLock`/`indexingLock`）
- Task 7：`ScreenshotService` 加 `@MainActor` + 清理 `DispatchQueue` + `FrozenWindowSnapshot` 改用 `SendableCGImage`
- Task 8：Actor 内部隔离修复（`notifyChanged()`、Combine sink）
- Task 9：`@preconcurrency import` 管理
- Task 11：开启 `-strict-concurrency=complete` → Swift 6 语言模式

## 关键架构决策

1. **所有全局单例 → `@MainActor`**（它们都持有 `@Published` 或 UI 状态）
2. **已有 actor 保持不变**：`CaptureLibraryWorker`、`CaptureLibraryDatabase`、`CaptureLibrarySemanticSearchService`
3. **`@unchecked Sendable` 仅允许 `SendableCGImage`**，必须附带 `// SAFETY:` 注释
4. **`DispatchQueue.main.async` → 直接调用**（已在 `@MainActor`）或 `Task { @MainActor in }`（从非隔离上下文）
5. **`DispatchQueue.main.asyncAfter` → `Task { try? await Task.sleep(nanoseconds:) }`**
6. **`NSLock` → 移除**，`@MainActor` 保证串行访问
7. **`SCWindow`/`SCRunningApplication` 不跨隔离域传递**，在捕获点扁平化为 `WindowCaptureInfo`
8. **`Task.detached` 在 `enqueue()` 和 `saveToDiskAsync()` 中是刻意的**——需要切断 `@MainActor` 继承
9. **Combine sink 闭包用 `Task { @MainActor in }` 模式**，`MainActor.assumeIsolated` 仅作最后手段且必须附 SAFETY 注释

## 文件位置速查

| 类型 | 文件 |
|------|------|
| SendableCGImage, 所有模型 | `PastScreen/Services/CaptureLibrary/CaptureLibraryModels.swift` |
| EdgeInsetValues, WindowCaptureInfo | `PastScreen/Services/WindowCaptureCoordinator.swift` |
| CaptureLibraryAddJob | `PastScreen/Services/CaptureLibrary.swift` |
| AppSettings + 值类型 | `PastScreen/Models/AppSettings.swift` |
| 测试文件 | `PastScreen-CNTests/` |
