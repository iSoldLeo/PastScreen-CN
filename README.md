# 📸 PastScreen-CN

**面向 macOS 开发者的超快截图工具，截图即刻进入剪贴板。**

[![Platform](https://img.shields.io/badge/platform-macOS%2014+-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)

> 选区截图只需毫秒级，复制到剪贴板后继续写代码。

---

## 📥 获取 PastScreen-CN

### 📦 GitHub Releases

你可以从 GitHub Releases 下载最新版本：

https://github.com/iSoldLeo/PastScreen-CN/releases

首次打开时若被系统拦截，请使用以下任一方式放行：

- 右键 App -> 打开（首次）
- 执行：`xattr -dr com.apple.quarantine /Applications/PastScreen-CN.app`

## 🆕 近期更新

- **全局热键可自定义**：在设置里录制任意按键组合，默认是 ⌥+⌘+S
- **前台也能触发热键**：设置窗口打开时也可以截图
- **右键取消截图**：进入选区后右键即可取消
- **使用 macOS 原生截图音效**

---

## ✨ 核心特性

- **即时剪贴板**：截图直接写入剪贴板，粘贴即可用
- **可配置热键**：任意组合键都可以作为截图触发
- **应用级规则**：为特定应用强制“仅路径 / 仅图片”
- **菜单栏原生体验**：原生、轻量、无需 Dock
- **液态玻璃选区**：半透明叠层 + HUD 选区
- **Apple 原生通知**：截图完成后通知并可在 Finder 中定位
- **快捷指令支持**：App Intents / 自动化 / Spotlight

---

## 🧭 使用方式

1) 按热键进入选区（默认 ⌥+⌘+S）  
2) 拖拽选择区域，或右键取消  
3) 在设置中可修改热键、保存路径、图片格式与应用规则

---

## 🧩 技术栈

- **Swift 5.9**，AppKit + SwiftUI 混合 UI
- **ScreenCaptureKit** 高质量截图
- **TipKit & AppIntents**（macOS 14+）

---

## 🔐 权限说明

| 权限 | 用途 |
|------|------|
| 屏幕录制 | ScreenCaptureKit 截图所需 |
| 辅助功能 | 全局热键触发 |
| 通知 | 截图完成通知 |

**隐私**：PastScreen-CN 不上传、不联网，所有操作都在本地完成。

---

### 🛠 源码构建

PastScreen-CN **完全开源**，你也可以自己构建：

```bash
git clone https://github.com/iSoldLeo/PastScreen-CN.git
cd PastScreen-CN
open PastScreen-CN.xcodeproj
```

然后在 Xcode 中 `Cmd + R` 运行。

---


## 🙌 致谢与许可

项目基于 [GPL-3.0 license](LICENSE) 开源。

欢迎提 Issue、讨论想法或提交 PR。祝你截图愉快！⚡️
