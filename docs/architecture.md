# Mio 架构文档

> 当前基线：Swift 6.3.x strict concurrency · macOS 14.6+ · Xcode 26
> 代码规模：45 个 Swift 文件，约 4,400 行
> 第三方依赖：无（仅系统框架）

---

## 1. 目录结构

```
Mio/
├── MioApp.swift              @main 入口 + AppDelegate
├── Info-AppStore.plist       Bundle 配置
├── MioAppStore.entitlements  沙盒能力声明
│
├── Application/              组合层：协调 UI → Pipeline 流转
│   ├── CaptureCoordinator.swift     UI 入口与 Pipeline 之间的桥
│   └── CapturePipeline.swift        actor，执行截图流水线
│
├── Domain/                   契约层：纯值类型 + 协议
│   ├── CaptureConfiguration.swift   不可变配置 DTO
│   ├── CaptureImage.swift           图像 DTO（@unchecked Sendable）
│   ├── CaptureEvent.swift           事件枚举
│   ├── CaptureError.swift           错误类型
│   ├── ImageFormat.swift            图像格式枚举
│   ├── CaptureClipboardFormat.swift 剪贴板模式枚举
│   ├── EventBusing.swift            ┐
│   ├── ScreenCapturing.swift        │ 服务协议
│   ├── ImageRendering.swift         │
│   ├── CaptureOutputWriting.swift   ┘ FileWriting + ClipboardWriting
│   └── …                            其他 DTO（窗口命中测试等）
│
├── Infrastructure/           基础设施实现
│   ├── DependencyContainer.swift    @MainActor 组合根
│   ├── CaptureEventBus.swift        EventBusing 实现（AsyncStream）
│   └── WindowCaptureService.swift   Quartz 窗口命中测试
│
├── Services/                 服务实现
│   ├── DisplayCaptureService.swift  ScreenCapturing 实现（actor）
│   ├── ImageRenderService.swift     ImageRendering 实现（actor）
│   ├── FileOutputService.swift      FileWriting 实现（actor，持有序号计数）
│   ├── ClipboardOutputService.swift ClipboardWriting 实现（@MainActor）
│   ├── HotKeyManager.swift          全局热键（NSEvent 监听）
│   ├── PermissionManager.swift      权限检查与引导
│   └── LaunchAtLoginManager.swift   开机自启（async）
│
├── Models/
│   └── AppSettings.swift     聚合根，持有四个主题 store
│
├── Settings/                 主题化设置 store
│   ├── AppearanceSettings.swift     语言 / Dock / 自启
│   ├── CaptureSettings.swift        截图 / 文件夹 / 剪贴板格式
│   ├── HotKeySettings.swift         全局热键
│   ├── UISettings.swift             窗口边框 / 选区限制
│   ├── HotKey.swift                 ┐
│   ├── RGBAColor.swift              │ 共享值类型
│   ├── AppLanguage.swift            │
│   └── SaveFolderBookmarkStore.swift 安全作用域书签
│
├── Components/
│   └── LiquidGlassComponents.swift  SwiftUI Liquid Glass 容器
│
├── Views/
│   ├── MenuBarContentView.swift     菜单栏内容
│   ├── SettingsView.swift           偏好设置窗口
│   ├── SelectionWindow.swift        选区覆盖窗口
│   └── DynamicIslandView.swift      操作反馈
│
├── Utils/
│   └── Localization.swift    Bundle swizzling，运行时切语言
│
└── *.lproj/                  11 套本地化资源
```

---

## 2. 截图流水线

```
HotKey / MenuBar
        │
        ▼
AppDelegate.takeScreenshot()
        │  (NotificationCenter)
        ▼
CaptureCoordinator
   ├── 显示 SelectionWindow
   ├── 用户拖框 → didSelectRect / didSelectWindow
   ├── 构造 CaptureRequest
   └── 调用 pipeline.execute(request:)
        │
        ▼
CapturePipeline (actor)
   ├── displayCapture.captureDisplay/Window  → CaptureImage
   ├── imageRender.addBorder (窗口截图启用时)
   ├── fileOutput.write (saveToFile + 有效书签时)
   ├── clipboardOutput.copy
   └── 通过 EventBus 广播：started / captured / savedToFile / copiedToClipboard
        │
        ▼
CaptureCoordinator 监听 EventBus
   └── 显示 DynamicIsland 反馈
```

入口：UI 触发 → `Coordinator` 协调选区与配置组装。
执行：`CapturePipeline` actor 串行编排 4 个服务调用。
反馈：`EventBus` AsyncStream 单向事件流。

---

## 3. 隔离模型

| 类型 | 隔离 | 说明 |
|---|---|---|
| `MioApp` / `AppDelegate` | `@MainActor` | SwiftUI 入口、菜单栏、AppKit 委托 |
| `CaptureCoordinator` | `@MainActor` | 监听 EventBus 并驱动 UI |
| `CapturePipeline` | `actor` | 后台编排服务调用 |
| `DisplayCaptureService` | `actor` | ScreenCaptureKit 调用 |
| `ImageRenderService` | `actor` | CGContext 渲染 |
| `FileOutputService` | `actor` | 磁盘 IO + 内置序号计数 |
| `ClipboardOutputService` | `@MainActor` | NSPasteboard 主线程亲和 |
| `AppSettings` 系列 | `@MainActor` | UserDefaults + SwiftUI 绑定 |
| `CaptureEventBus` | `nonisolated` + `@unchecked Sendable` | AsyncStream Continuation 跨 actor |
| 协议（EventBusing 等）| `Sendable` + `nonisolated` 方法 | 跨隔离调用安全 |
| 值类型（CaptureImage / Configuration / DTO） | `Sendable` | 跨边界传递 |

xcconfig 启用 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，**所有未显式标隔离的代码默认在主 actor 上**。需要跨 actor 调用的接口必须显式标 `nonisolated`。

---

## 4. 配置流转

```
UserDefaults
     ↑↓
{Capture/UI/HotKey/Appearance}Settings (@MainActor ObservableObject)
     │
     │  (SwiftUI 通过 @EnvironmentObject 订阅各 store)
     ↓
SettingsView / MenuBarContentView 等
```

```
AppSettings.shared
     │
     ├── capture     CaptureSettings
     ├── ui          UISettings
     ├── hotkey      HotKeySettings
     └── appearance  AppearanceSettings
```

`AppSettings` 仅作聚合容器，自身不再 `ObservableObject`；SwiftUI 视图按主题精确订阅子 store，避免无关字段变更触发重绘。

`CaptureCoordinator.makeCaptureConfiguration()` 把当前 settings 拍快照成 `CaptureConfiguration`（不可变 Sendable 值），传入 pipeline。

---

## 5. 关键设计决策

| 决策 | 原因 |
|---|---|
| Application / Domain / Services / Infrastructure 分层 | Domain 仅含值类型与协议，无依赖；Services / Infrastructure 实现协议；Application 组合 |
| 5 个服务全部协议化（EventBusing / FileWriting / ClipboardWriting / ScreenCapturing / ImageRendering） | 测试可注入替代实现，DI 容器统一管理 |
| 设置按主题拆为 4 个 store | 避免 SwiftUI 全量重绘；每个主题独立持久化与副作用边界 |
| FileOutputService 内置序号计数 | 序号是文件输出实现细节，不属于用户偏好 |
| UserDefaults key 字符串字面量保留 | 兼容存量用户，避免迁移 |
| App Icon 使用 `Mio.icon`（Icon Composer） | 支持 macOS 26 Liquid Glass 多层效果 |
| Bundle swizzling 运行时切语言 | `Localization.swift` 提供 in-app 切换，不依赖系统语言 |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | 默认 main，跨 actor 接口显式 `nonisolated` |

---

## 6. 构建与发布

| 项 | 值 |
|---|---|
| Bundle ID | `com.iSoldLeo.Mio` |
| Module Name | `Mio` |
| Deployment Target | macOS 14.6 |
| Swift Language | 6.0（with strict concurrency complete） |
| Architecture | arm64（仅 Apple Silicon） |
| Code Signing | Automatic（开发期 ad-hoc） |
| Sandbox | Enabled（`MioAppStore.entitlements`） |
| CI | GitHub Actions（`.github/workflows/release.yml`、`beta.yml`） |

---

## 7. 已知盲区

- 所有 Phase 1–6 重构期间的命令行 typecheck 未带 `-default-isolation MainActor` flag，部分隔离合规结论需要用正确 flag 重审。这一项作为后续工作单独跟进。
- `architecture.md` 仅做高层结构与决策记录，详细实现请参阅源码与单元注释。
