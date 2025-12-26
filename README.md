<p align="center">
  <img src="./PastScreen/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="PastScreen-CN icon" width="160" height="160">
</p>
<h1 align="center">📸 PastScreen-CN</h1>
<p align="center">极速截图，自动进剪贴板。原生应用，小而快。</p>
<p align="center">
  <a href="https://www.apple.com/macos/">
    <img src="https://img.shields.io/badge/platform-macOS%2014.6+-blue.svg" alt="Platform macOS 14.6+">
  </a>
  <a href="https://swift.org/">
    <img src="https://img.shields.io/badge/Swift-5.9-orange.svg" alt="Swift 5.9">
  </a>
  <br>
  <a href="./README-EN.md" style="color:#0a84ff; font-weight:600; text-decoration:none;">English README</a>
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
   - OCR 截图：默认 ⌥⌘⇧O（识别文字并复制到剪贴板）  
   - 全屏截图：菜单栏「全屏截图」
5. **取消/查看**：选区中右键取消；完成后菜单栏可「查看最后一次截图」、从「最近 10 条」复制，或打开「素材库」管理。

---

## 核心特性
- 极速选区，原生剪贴板，无中间弹窗
- 高级截图内置标注 + OCR，支持独立热键
- 素材库（本地）：置顶/标签/备注/按应用归档，支持搜索与过滤语法
- 可录制任意组合的全局/高级热键
- 菜单栏应用，不占 Dock，含历史记录与快捷入口
- 应用规则：为特定 App 强制「仅路径」或「仅图片」
- 截图边框可配置（开关/宽度/圆角/颜色）
- 自定义编辑工具启用与顺序，支持快捷轮盘

---

## 设置要点
- **热键**：在设置 > 截图中录制；支持高级截图独立热键与 OCR
- **保存**：默认只剪贴板；如需落盘，在设置 > 存储里选目录并开启保存
- **格式**：PNG 或 JPEG，可选带边框输出
- **应用规则**：为终端/IDE 等指定「仅路径」或「仅图片」
- **素材库**：可选存预览图/自动 OCR/语义增强（实验），并支持按策略自动清理
- **OCR 语言**：在设置 > 编辑 > OCR 勾选；不勾选则使用系统默认/自动检测
- **语言**：跟随系统 / 简体中文 / English / 繁体中文 / 多国语言（nl/de/fr/es/ja/ko 等）

---

## 窗口截图（点击取窗）

- 任意截图热键触发后，将鼠标悬停到窗口自动高亮，单击即可截整窗；拖拽框选仍可截区域。
- 普通 / 高级 / OCR 模式均支持取窗，完成后同样进剪贴板/素材库（如已开启保存）。
- 边框与圆角：默认保留 macOS 窗口圆角，可在设置 > 截图中关闭或自定义边框宽度、圆角、颜色。
- 防遮罩：开拍前会冻结背景，避免把遮罩/高亮带入成品；如窗口刚出现未命中，重新点一次即可。
- 多屏：每块屏幕都有遮罩与高亮，直接在目标屏幕单击即可截取对应窗口。

---

## 素材库搜索语法（可选）
素材库窗口的搜索框支持“空格分词”的过滤语法（过滤条件会从搜索词里剥离）：

- `pinned` / `pin` / `置顶`
- `#标签`（也支持 `＃标签`）或 `tag:xxx` / `标签:xxx`
- `app:xxx` / `应用:xxx`（支持 bundle id 或应用名关键字，如 `app:com.apple.Safari` / `app:chrome`）
- `type:area|window|fullscreen`（也支持 `选区/窗口/全屏`）
- 时间：`今天` / `昨天`，`本周/上周/本月/上月/今年/去年`，`7d` / `2w` / `3m`，或 `2025-12-24` / `12-24`

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

- 技术栈：Swift，AppKit + SwiftUI，ScreenCaptureKit，Vision（OCR），SQLite（素材库）；TipKit（macOS 14+）/ AppIntents（macOS 13+）为可选能力
- 本地构建：

```bash
git clone https://github.com/iSoldLeo/PastScreen-CN.git
cd PastScreen-CN
open PastScreen-CN.xcodeproj   
```

---

## 许可证与致谢

- 本仓库整体采用 [GPL-3.0 license](LICENSE/GPL-3.0%20license) 分发。
- 上游代码按 MIT License 授权，保留其版权声明（见 [LICENSE/MIT](LICENSE/MIT)）。

欢迎提 Issue / PR，一起把体验做得更好。 🎯
