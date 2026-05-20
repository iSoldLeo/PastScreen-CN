# PastScreen 截图流水线优化方案

> 基于 `01-current-pipeline.md` 现状分析，以实现为导向的方案文档。
> 目标：用最小改动实现最大性能收益，从 650ms 最坏路径压到 ~200ms。

---

## 0. 一句话目标

> 热键按下到「图已进剪贴板 + 通知闪现」全程 < 200ms。
> 目前最坏路径约 650ms，优化后目标 150-200ms。

---

## 1. 优化后的完整流程（标注改动点）

```
┌─────────────────────────┐
│ 触发来源                │
│  • 全局热键              │
│  • 菜单栏点击            │
│  • App Intents           │
└──────────┬──────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────┐
│ AppDelegate.handleHotKeyPressed                          │
│  • requestScreenRecordingIfNeeded                        │
│  • ~~Task.sleep(50ms)~~  → [优化] 条件触发/事件驱动      │
│  • screenshotService.captureScreenshot(trigger:)          │
└──────────┬───────────────────────────────────────────────┘
           │
           ▼
┌────────────────────────────────────────────────────────────────────┐
│ ScreenshotService.startSelectionFlow                               │
│                                                                    │
│  [优化] Display snapshot: withTaskGroup 并发抓取                   │
│       → 每屏 captureDisplaySnapshot() 并行                         │
│                                                                    │
│  [优化] Window snapshot: withTaskGroup 并发 burst                  │
│       → 每窗 captureWindowSnapshot() 并行（上限 3）                │
│                                                                    │
│  SelectionWindow(frozenScreenshots:) 显示                          │
└──────────┬─────────────────────────────────────────────────────────┘
           │  用户拖框 / 点窗口 / ESC
           ▼
┌────────────────────────────────────────────────────────────────────┐
│ SelectionWindowDelegate 回调                                       │
│  • ~~Task.sleep(150ms)~~ → [优化] vsync 或事件驱动                 │
│  • frozenCapture 命中 → 直接走 frozen 路径                         │
│  • 未命中 → performCapture                                         │
└──────────┬─────────────────────────────────────────────────────────┘
           │
           ▼
┌────────────────────────────────────────────────────────────────────┐
│ handleSuccessfulCapture                                            │
│  • copyToClipboard（PNG 数据写剪贴板）                             │
│  • CaptureLibrary.shared.addCapture（异步入库，不阻塞）            │
│  • [优化] saveToDiskAsync → CGImageDestination + HEIC              │
│  • showSuccessNotification                                         │
└────────────────────────────────────────────────────────────────────┘
```

---

## 2. 四项改动的具体实现

### 2.1 改动一：saveToFile 改 HEIC + CGImageDestination（ROI 最大）

**现状**：`saveToFile` 走 `NSBitmapImageRep(cgImage:) → NSBitmapImageRep.representation(using: .png)`，retina 全屏图编码 **150-300ms**。

**优化后**：`CGImageDestinationCreateWithURL → kUTTypeHEIC → CGImageDestinationAddImage`，走硬件编码器，编码降至 **10-50ms**。

**实现要点**：

```swift
// saveToFile 内的新实现
static func encodeImageToHEIC(cgImage: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.heic.identifier as CFString,
        1,
        nil
    ) else {
        throw EncodingError.heicDestinationCreationFailed
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw EncodingError.heicFinalizationFailed
    }
    return data as Data
}
```

- HEIC 失败时自动 fallback 到现有 PNG 路径，保证可靠性
- 文件扩展名从 `.png` → `.heic`（或保留 `.png` 但用 HEIC 编码，不推荐）
- 文件大小减半，磁盘 I/O 也减少

**收益**：150-300ms → 10-50ms，单点最大 ROI。

---

### 2.2 改动二：Window snapshot 串行 → 并发 burst

**现状**：`prepareFrozenWindowSnapshotsWithScreenCaptureKit` 内串行 `for` 每个窗口，5 窗约 **150-250ms**，13 窗约 **275-500ms**。

**优化后**：用 `withTaskGroup` 并发抓取，上限 3 个并发（受 SCKit 系统限制），6 窗实测可从 ~250ms 压到 ~140ms。

**实现要点**：

```swift
let windowSnapshots = await withTaskGroup(of: (CGWindowID, FrozenWindowSnapshot)?.self) { group in
    for window in windows {
        group.addTask {
            // captureWindowSnapshot 内部调 SCKit
            let snapshot = try? await self.captureWindowSnapshot(window: window)
            return snapshot.map { (window.windowID, $0) }
        }
    }
    var results: [CGWindowID: FrozenWindowSnapshot] = [:]
    for await result in group {
        if let (id, snapshot) = result {
            results[id] = snapshot
        }
    }
    return results
}
```

- 上限设为 3，超过排队（系统并发上限约 2-3，来自 sck_burst_probe 实测）
- `SCShareableContent` 在改动 3 中统一复用，这里只抓窗口 snapshot
- 异常窗口（如视频、全屏覆盖）不阻塞其他窗口

**收益**：150-500ms → 80-150ms（取决于窗口数）。

---

### 2.3 改动三：Display snapshot 串行 → 并发

**现状**：`prepareFrozenDisplaySnapshotsWithScreenCaptureKit` 内串行 `for` 每屏，2 屏约 **150ms**。

**优化后**：同样 `withTaskGroup` 并行，2 屏节省 **50-100ms**。

**实现要点**：

```swift
let displaySnapshots = await withTaskGroup(of: (CGDirectDisplayID, SendableCGImage)?.self) { group in
    for screen in NSScreen.screens {
        group.addTask {
            let snapshot = try? await self.captureDisplaySnapshot(screen: screen, ...)
            return snapshot.map { (screen.displayID, $0) }
        }
    }
    // ... collect results
}
```

- Display 数量通常 1-2 个，并发收益有限但稳定
- 与 Window snapshot 的 TaskGroup 逻辑独立，互不阻塞

**收益**：多屏场景节省 **50-100ms**。

---

### 2.4 改动四：硬等待（50ms / 150ms / 100ms）优化

**现状**：三处 `Task.sleep`：

| 位置 | 时长 | 目的 | 问题 |
|------|------|------|------|
| AppDelegate.performXxxCapture | 50ms | 等权限 alert 关闭 | 历史遗留，多数场景不需要 |
| SelectionWindowDelegate 回调 | 150ms | 等 overlay 视觉消失 | 固定延迟，用户能感知 |
| scheduleSelectionCleanup | 100ms | 等 cleanup 完成 | 不影响用户感知 |

**优化方向**：

- **150ms 主优化**：用 `NSWindow` 的 `orderOut` 回调或 vsync 事件替代固定 sleep。理想路径：overlay `orderOut` → 下一帧渲染完成 → 立即开始 capture，延迟从 150ms 压到 **16ms（一帧）**。
- **50ms 次优化**：改为条件触发——只在检测到权限 alert 未关闭时才 sleep，否则直接 pass-through。
- **100ms cleanup**：不变（不影响用户）。

**实现要点（150ms）**：

方案 A（最小改动）：把 `Task.sleep(150ms)` 降到 `Task.sleep(50ms)`，凭经验观察 50ms 是否足够 overlay 淡出。

方案 B（推荐）：监听 `NSWindow` 的 `windowDidOrderOut` 通知，overlay 真正消失后再开始 capture。

方案 C（最佳）：用 `CATransaction` 动画 completion 或 `CADisplayLink` 确保 overlay 渲染帧已完成。

```swift
// 方案 B 伪代码
await withCheckedContinuation { continuation in
    var observer: NSObjectProtocol?
    observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didOrderOutNotification,
        object: selectionWindow,
        queue: .main
    ) { _ in
        NotificationCenter.default.removeObserver(observer!)
        continuation.resume()
    }
    selectionWindow.hide()
}
// overlay 真正消失后继续
```

**收益**：150ms → 16-50ms，节省 **100-134ms**。

---

## 3. 性能收益预测

### 最坏路径（选区截图 + 多屏 + 落盘）

```
优化前:
  50 (sleep) + 200 (display snapshot) + 150 (sleep) + 200 (region capture)
  + 100 (clipboard) + 200 (落盘 PNG)
  = 用户操作前 250ms + 操作后 650ms

优化后:
  0-10 (条件 sleep) + 100 (display 并发) + 16-50 (vsync 等待)
  + 100 (region capture) + 50 (clipboard) + 20 (HEIC 落盘)
  = 用户操作前 100ms + 操作后 170-220ms
```

**最坏路径总收益**：~650ms → ~200ms，压缩 **~70%**。

### 最优路径（命中 frozen + 单屏 + 单窗）

```
优化前: 50 + 80 + 150 + 0 + 50 = 330ms
优化后: 0  + 60 + 16  + 0 + 50 = 126ms
```

**最优路径收益**：~330ms → ~130ms，压缩 **~60%**。

---

## 4. 实施顺序

| 顺序 | 改动 | 改动量 | ROI | 风险 | 预估时间 |
|------|------|--------|-----|------|---------|
| **1** | saveToFile → HEIC | 改一个函数，加 fallback | ⭐⭐⭐ 150-250ms | 低（fallback 保证） | 半天 |
| **2** | 150ms sleep → vsync | 改回调链一处 | ⭐⭐ 100-134ms | 中（需测试各 macOS 版本） | 半天 |
| **3** | Window snapshot 并发 | withTaskGroup 重构一个函数 | ⭐⭐ 100-300ms | 低（sck_burst_probe 已验证） | 1 天 |
| **4** | Display snapshot 并发 | withTaskGroup 重构一个函数 | ⭐ 50-100ms | 低 | 半天 |
| **5** | 50ms sleep → 条件触发 | 加条件判断 | ⭐ 50ms | 低 | 半天 |

**推荐按 1→2→3→4→5 顺序推进**。改动 1 和 2 是「单点改动、立刻见效」类型，1 天即可完成并获得显著感知提升。改动 3-5 后续逐步追加。

---

## 5. 边界与约束

- **HEIC 回退**：`CGImageDestination` 失败（如旧版 macOS）自动回退到现有 PNG 路径，不破坏兼容性
- **并发上限**：Window snapshot burst 上限 3，系统超过会排队，实测已确认（sck_burst_probe）
- **Display 并发**：Display 通常只有 1-2 个，并发收益有限但稳定
- **vsync 等待**：方案 B（orderOut 通知）在 macOS 各版本兼容性待验证，若有问题回退到方案 A（缩短 sleep）
- **不改动范围**：编辑器渲染、OCR 识别、Dynamic Island 通知、CaptureLibrary SQLite worker 不在本次优化范围

---

## 6. 验证方式

每项改动完成后，用以下指标验证：

| 指标 | 优化前 | 优化后目标 | 测量方式 |
|------|--------|-----------|---------|
| 热键→选区出现 | ~250ms | < 150ms | 手动秒表 / instrument |
| 松开鼠标→通知闪现 | ~650ms | < 250ms | 手动秒表 / instrument |
| 落盘编码时间 | 150-300ms | < 50ms | `saveToFile` 前后计时 |
| Window snapshot 总耗时 | 250-500ms | < 150ms | `prepareFrozenWindowSnapshots` 前后计时 |

---

*文档创建：2026-05-18*
*前置文档：`01-current-pipeline.md`（现状分析）*
