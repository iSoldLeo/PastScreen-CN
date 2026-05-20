# PastScreen 函数迁移追踪表

## 纪律

1. **迁移前**：在下方表格中登记旧函数 → 新函数的对应关系
2. **迁移中**：逐行对比，确认输入输出、错误路径、副作用一致
3. **迁移后**：编译验证零 warning，在 Status 列打勾
4. **全部迁移完成后**：删除旧文件，再次编译验证

---

## ScreenshotService → 新架构映射

| # | 旧函数 | 旧文件:行 | 新函数 / 新位置 | 状态 | 验证人 | 备注 |
|---|--------|-----------|-----------------|------|--------|------|
| 1 | `captureScreenRegion(rect:excludeWindowIDs:)` | ScreenshotService.swift:882 | `DisplayCaptureService.captureDisplay(rect:excludingWindowIDs:)` | ⏳ 待迁移 | | 核心区域捕获逻辑 |
| 2 | `captureDisplaySnapshot` | ScreenshotService.swift:561 | `DisplayCaptureService.captureDisplay(rect:excludingWindowIDs:)` | ⏳ 待迁移 | | 全屏捕获可复用 #1 |
| 3 | `captureWindowSnapshot(window:applyBorder:)` | ScreenshotService.swift:579 | `DisplayCaptureService.captureWindow(windowID:)` | ⏳ 待迁移 | | 窗口捕获 |
| 4 | `applyFrozenBorderIfNeeded(cgImage:pointSize:)` | ScreenshotService.swift:669 | `ImageRenderService.addBorder(to:config:)` | ⏳ 待迁移 | | CALayer border 渲染 |
| 5 | `saveToFileAndGetPath(cgImage:pointSize:)` | ScreenshotService.swift:1205 | `FileOutputService.write(image:config:sequence:)` | ⏳ 待迁移 | | 文件保存 |
| 6 | `saveToFile(cgImage:pointSize:sequence:)` | ScreenshotService.swift:1147 | `FileOutputService.write(image:config:sequence:)` | ⏳ 待迁移 | | 静态方法版本 |
| 7 | `copyToClipboard(cgImage:pointSize:filePath:)` | ScreenshotService.swift:1041 | `ClipboardOutputService.copy(image:config:filePath:)` | ⏳ 待迁移 | | 剪贴板操作 |
| 8 | `handleSuccessfulCapture(result:trigger:)` | ScreenshotService.swift:1010 | `CapturePipeline.execute(request:)` + EventBus | ⏳ 待迁移 | | 成功后的编排 |
| 9 | `startSelectionFlow(trigger:)` | ScreenshotService.swift:361 | `CaptureCoordinator.captureScreenshot()` | ⏳ 待迁移 | | 选区流程启动 |
| 10 | `captureFullScreen(trigger:)` | ScreenshotService.swift:? | `CaptureCoordinator.captureFullScreen()` | ⏳ 待迁移 | | 全屏快捷键 |
| 11 | `captureWindowUnderMouse(trigger:mode:)` | ScreenshotService.swift:307 | `CaptureCoordinator.captureWindowUnderMouse()` | ⏳ 待迁移 | | 窗口快捷键 |
| 12 | `performCapture(mode:trigger:)` | ScreenshotService.swift:? | `CapturePipeline.execute(request:)` | ⏳ 待迁移 | | 执行捕获 |
| 13 | `performWindowCapture(...)` | ScreenshotService.swift:821 | `CapturePipeline.execute(request: .window(...))` | ⏳ 待迁移 | | 窗口捕获执行 |
| 14 | `performAdvancedCapture(...)` | ScreenshotService.swift:786 | *(已删除功能)* | ❌ 不迁移 | | advanced 链路已在前期砍掉 |
| 15 | `performAdvancedWindowCapture(...)` | ScreenshotService.swift:859 | *(已删除功能)* | ❌ 不迁移 | | advanced 链路已在前期砍掉 |
| 16 | `handleAdvancedCapture(...)` | ScreenshotService.swift:907 | *(已删除功能)* | ❌ 不迁移 | | advanced 链路已在前期砍掉 |
| 17 | `visibleWindowIDsByDisplay` | ScreenshotService.swift:492 | `WindowCaptureService` 内部使用 | ⏳ 待迁移 | | 窗口列表枚举 |
| 18 | `prepareFrozenWindowSnapshotsWithScreenCaptureKit` | ScreenshotService.swift:464 | `CaptureCoordinator` 持有 | ⏳ 待迁移 | | 冻结窗口快照 |
| 19 | `frozenCapture(...)` | ScreenshotService.swift:638 | `CaptureCoordinator` | ⏳ 待迁移 | | 冻结捕获流程 |
| 20 | `selectionWindow(...)` | ScreenshotService.swift:164 | `CaptureCoordinator` | ⏳ 待迁移 | | 选区窗口管理 |
| 21 | `showErrorNotification(error:)` | ScreenshotService.swift:757 | `CaptureCoordinator` / EventBus | ⏳ 待迁移 | | 错误通知 |

---

## WindowCaptureCoordinator → 新架构映射

| # | 旧函数 | 旧文件:行 | 新函数 / 新位置 | 状态 | 验证人 | 备注 |
|---|--------|-----------|-----------------|------|--------|------|
| 1 | `hitTestFrontmostWindowAtMouse(...)` | WindowCaptureCoordinator.swift:120 | `WindowCaptureService.hitTestFrontmostWindowAtMouse(...)` | ⏳ 待迁移 | | 鼠标位置窗口 hit-test |
| 2 | `hitTestFrontmostWindow(...)` | WindowCaptureCoordinator.swift:? | `WindowCaptureService.hitTestFrontmostWindowAtMouse(...)` | ⏳ 待迁移 | | 重载版本 |
| 3 | `captureWindow(with:applyBorder:)` | WindowCaptureCoordinator.swift:256 | `DisplayCaptureService.captureWindow(windowID:)` | ⏳ 待迁移 | | 窗口捕获 |
| 4 | `captureWindow(using:applyBorder:)` | WindowCaptureCoordinator.swift:322 | `DisplayCaptureService.captureWindow(windowID:)` | ⏳ 待迁移 | | 通过 hitResult 捕获 |
| 5 | `addBorderIfNeeded(cgImage:pointSize:config:)` | WindowCaptureCoordinator.swift:338 | `ImageRenderService.addBorder(to:config:)` | ⏳ 待迁移 | | border 渲染 |
| 6 | `WindowHitTestResult` struct | WindowCaptureCoordinator.swift:? | `WindowCaptureService` 内部 / Domain | ⏳ 待迁移 | | 需要定义类型 |

---

## 入口点调用更新追踪

| # | 调用者文件 | 当前调用对象 | 目标调用对象 | 状态 | 备注 |
|---|-----------|-------------|-------------|------|------|
| 1 | `PastScreenApp.swift:45` | `ScreenshotService()` | `DependencyContainer.captureCoordinator` | ⏳ 待更新 | App 入口 |
| 2 | `SelectionWindow.swift:440` | `WindowCaptureCoordinator.shared.hitTestFrontmostWindowAtMouse` | `WindowCaptureService.hitTestFrontmostWindowAtMouse` | ⏳ 待更新 | 选区窗口双击取窗 |
| 3 | `HotKeyManager.swift` | `ScreenshotService` | `CaptureCoordinator` | ⏳ 待更新 | 全局热键 |
| 4 | `MenuBarContentView.swift` | `ScreenshotService` | `CaptureCoordinator` | ⏳ 待更新 | 菜单栏按钮 |

---

## 状态图例

| 符号 | 含义 |
|------|------|
| ⏳ | 待迁移 / 待更新 |
| 🔄 | 迁移中 |
| ✅ | 已完成并验证 |
| ❌ | 不迁移（功能已删除） |
