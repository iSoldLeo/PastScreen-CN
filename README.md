<p align="center">
  <img src="./PastScreen/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="PastScreen-CN icon" width="160" height="160">
</p>
<h1 align="center">📸 PastScreen-CN</h1>
<p align="center">极速截图，自动进剪贴板。原生应用，小而快。</p>
<p align="center">
  <a href="https://www.apple.com/macos/">
    <img src="https://img.shields.io/badge/platform-macOS%2014+-blue.svg" alt="Platform macOS 14+">
  </a>
  <a href="https://swift.org/">
    <img src="https://img.shields.io/badge/Swift-5.9-orange.svg" alt="Swift 5.9">
  </a>
</p>

---

## 立即开始（用户指南）

1. **下载**：从 Releases 获取最新版本  
   https://github.com/iSoldLeo/PastScreen-CN/releases
2. **放行首次启动**：右键 App -> 打开（一次即可），或执行  
   `xattr -dr com.apple.quarantine /Applications/PastScreen-CN.app`
3. **授权**：按提示允许 *屏幕录制*、*辅助功能*、*通知*。
4. **截图**：
   - 选区截图：默认 ⌥⌘S（可在设置中修改）  
   - 高级截图：默认 ⌥⌘⇧S（内置标注器）  
   - 全屏截图：菜单栏「全屏截图」
5. **取消/查看**：选区中右键取消；完成后菜单栏可「查看最后一次截图」或从历史复制。

---

## 核心特性
- 极速选区，原生剪贴板，无中间弹窗
- 可录制任意组合的全局/高级热键
- 菜单栏应用，不占 Dock
- 应用规则：为特定 App 强制「仅路径」或「仅图片」
- 内置标注器（高级截图）

---

## 设置要点
- **热键**：在设置 > 截图中录制；支持高级截图独立热键
- **保存**：默认只剪贴板；如需落盘，在设置 > 存储里选目录并开启保存
- **格式**：PNG 或 JPEG
- **应用规则**：为终端/IDE 等指定「仅路径」或「仅图片」
- **语言**：跟随系统 / 简体中文 / English

---

## 权限与隐私

| 权限       | 用途                          |
|------------|------------------------------|
| 屏幕录制   | ScreenCaptureKit 截图        |
| 辅助功能   | 全局快捷键                   |
| 通知       | 完成提示与「在 Finder 中显示」 |

PastScreen-CN 离线运行，不上传、不联网。

---

## 常见问题
- **热键不生效**：确认辅助功能已授权；在设置里重新录制后再试。
- **首次打开被拦截**：右键打开一次，或执行上方 `xattr` 命令。

---

## 开发者信息

- 技术栈：Swift 5.9，AppKit + SwiftUI，ScreenCaptureKit，TipKit & AppIntents（macOS 26+）
- 本地构建：

```bash
git clone https://github.com/iSoldLeo/PastScreen-CN.git
cd PastScreen-CN
open PastScreen-CN.xcodeproj   
```

---

## 许可证与致谢

- 本仓库整体采用 [GPL-3.0 license](LICENSE/GPL-3.0%20license) 分发。
- 上游代码按 MIT License 授权，保留其版权声明（见 LICENSE/MIT.md）。

欢迎提 Issue / PR，一起把体验做得更好。 🎯
