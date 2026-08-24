<div align="center">
<img src="docs/mio-icon-rounded.png" width="140" alt="Mio">
<h1>Mio</h1>
<p><b>macOS 截图工具。</b></p>
<p>
  <a href="https://github.com/iSoldLeo/Mio/releases/latest"><b>下载&nbsp;Mio</b></a> &nbsp;·&nbsp; <a href="README.md">English</a> &nbsp;·&nbsp; <a href="LICENSE/GPL-3.0%20license">License</a>
</p>
<p><sub>需要 macOS 15+ · Apple Silicon · 液态玻璃需 macOS 26+</sub></p>
<p><sub><b>Swift 6.3</b> &nbsp;·&nbsp; <b>SwiftUI · ScreenCaptureKit</b> &nbsp;·&nbsp; <b>离线运行</b> &nbsp;·&nbsp; <b>约 5&nbsp;MB</b> &nbsp;·&nbsp; <b>中&nbsp;/&nbsp;EN&nbsp;/&nbsp;日&nbsp;/&nbsp;FR&nbsp;/&nbsp;DE</b></sub></p>
</div>

## 一个不打扰你的截图工具。

按下快捷键，所有屏幕在 80&nbsp;ms 内定格在那一帧，你慢慢从静止画面里挑要的东西 — 一个窗口、一块区域，或者整张屏幕。窗口截图自带透明圆角。需要标注时，区域截图会交给内置编辑器。一切都留在你的 Mac 上。

Mio 只在菜单栏。不占 Dock。不需要登录。不联网。

<br>

<p align="center">
  <img src="docs/screenshot-framed-readme.png" width="70%" alt="Mio 输出样张">
</p>
<p align="center">
  <img src="docs/screenshot-onboarding-frame.png" width="70%" alt="画框截图">
</p>
<p align="center">
  <img src="docs/screenshot-onboarding-storage.png" width="70%" alt="保存设置">
</p>

<br>

## 新功能

- **内置编辑器。** 六种工具、三档粗细、七种预设色，加屏幕级吸管。
- **窗口截图自带透明圆角。** 圆角外不再糊着桌面壁纸。
- **三个独立快捷键。** 快速窗口、高级窗口（进编辑器）、全屏。

<br>

## 亮点

**截图**
- 每张屏幕在 80&nbsp;ms 内定格 — 从静止画面里挑，不用追着动画选
- 悬停高亮窗口；单击精准抠图，拖动框选区域
- 多屏全屏截图带屏幕选择器

**编辑**
- 矩形、椭圆、箭头、画笔、马赛克、文字
- 矢量文字直到确认前都可编辑
- 马赛克粒度固定 — 不会出现能反推回原图的「漏」马赛克
- 屏幕任何像素都能吸色

**原生**
- 菜单栏专属应用，不占 Dock
- Strict Concurrency，无第三方 SDK
- 零网络访问，零埋点

<br>

## 开始使用

从 [Releases](https://github.com/iSoldLeo/Mio/releases/latest) 下载 `Mio.app`，拖到「应用程序」文件夹，打开它。按提示授权 **屏幕录制**。

> 第一次启动如果 macOS 提示无法验证开发者，打开「**系统设置 → 隐私与安全性**」，往下滚到提示，点「**仍要打开**」。

<br>

## 隐私

Mio 完全在你的 Mac 上运行。截图进剪贴板，如果你开启了「保存到文件」也只去你选的目录。任何数据都不会离开设备 — 没有账号、没有埋点、没有分析，应用根本不发起网络连接。

<br>

## 信息

开发者 · [iSoldLeo](https://github.com/iSoldLeo) · [MeowLynxSea](https://github.com/MeowLynxSea) &nbsp;·&nbsp;
源码 · [github.com/iSoldLeo/Mio](https://github.com/iSoldLeo/Mio) &nbsp;·&nbsp;
反馈 · [报告问题](https://github.com/iSoldLeo/Mio/issues) &nbsp;·&nbsp;
许可证 · [GPL-3.0](LICENSE/GPL-3.0%20license)

<details>
<summary>从源码构建</summary>

```sh
git clone https://github.com/iSoldLeo/Mio.git
cd Mio
open Mio.xcodeproj
```

需要 Xcode 26+。选 `Mio` scheme 运行。

</details>
