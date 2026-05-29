//
//  EditorWindowController.swift
//  Mio
//
//  NSWindowController 标准模式管理编辑器窗口。
//  Cocoa 推荐容器，自带 retain/release 闭环 + showWindow/close 标准生命周期。
//
//  当前阶段（CH-E2）：仅显示截图 + 取消 / 完成两个按钮。
//  编辑工具在 CH-E3 起逐批落地（spec §11）。
//

import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let image: CaptureImage
    private let displayID: CGDirectDisplayID
    private let captureConfig: CaptureConfiguration
    private let frameConfig: FrameRenderer.Configuration
    private let pipeline: CapturePipeline

    init(
        image: CaptureImage,
        displayID: CGDirectDisplayID,
        config: CaptureConfiguration,
        frameConfig: FrameRenderer.Configuration,
        pipeline: CapturePipeline
    ) {
        self.image = image
        self.displayID = displayID
        self.captureConfig = config
        self.frameConfig = frameConfig
        self.pipeline = pipeline

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mio"
        // 红圆 / ⌘W = 取消（不弹「是否保存」对话框，符合 Mio 极简）

        super.init(window: window)
        window.delegate = self

        // SwiftUI 内容
        let view = EditorView(
            image: image,
            onCancel: { [weak self] in self?.cancel() },
            onFinish: { [weak self] composed in self?.finish(composed: composed) }
        )
        let host = NSHostingController(rootView: view)
        // 让 hosting controller 把 SwiftUI 视图的 fitting size 自动同步到
        // NSWindow.contentMinSize。SwiftUI EditorView 自己有 .frame(minWidth: 760,
        // minHeight: 760) 兜底，所以 fitting size 在 TextField 进出编辑时恒定，
        // 不会触发 contentMinSize 抖动。单一来源（SwiftUI .frame → fitting →
        // contentMinSize），无双层冲突。
        host.sizingOptions = [.minSize]
        window.contentViewController = host

        Self.configureSize(window: window, displayID: displayID, image: image)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - User actions

    /// 完成：EditorView 已经合成好最终 CGImage 传过来，包成 CaptureImage 后
    /// 经画框装饰（如启用）→ finishOutput → 关窗。
    /// 编辑器路径不响截图音效（playSound: false） — 音效已在 SelectionWindow
    /// 选定时由 coordinator 播过；这里走的是「保存」语义。
    /// 输出失败时**保留窗口**让用户重试或调整 saveToFile 设置后再试。
    func finish(composed: CGImage) {
        let composedImage = CaptureImage(
            cgImage: composed,
            scale: image.scale,
            size: image.size
        )
        // 路径 D：编辑后的成品贴画框（如启用），与路径 A 直出路径行为对齐。
        // 编辑器内部始终看原始图，画框只在最终输出阶段加上。
        let framedImage = FrameRenderer.compose(image: composedImage, config: frameConfig)
        let config = captureConfig
        let pipeline = self.pipeline
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pipeline.finishOutput(
                    image: framedImage,
                    config: config,
                    playSound: false
                )
                self.close()
            } catch {
                DynamicIslandManager.shared.show(
                    message: error.localizedDescription,
                    duration: 3.0,
                    style: .failure
                )
                // 不 close — 让用户决定下一步
            }
        }
    }

    /// 取消：直接关窗，不写盘不进剪贴板。
    func cancel() {
        close()
    }

    // MARK: - NSWindowDelegate

    /// macOS 26 SDK 起 NSWindowDelegate 整体已是 @MainActor 协议，
    /// 类自身也是 @MainActor，可直接同步调 Registry.deregister。
    func windowWillClose(_ notification: Notification) {
        EditorWindowRegistry.shared.deregister(self)
    }

    // MARK: - Sizing

    /// 默认尺寸（PRODUCT v4 §3.4）—— 只在窗口初始化时算一次，之后用户随意拖。
    ///
    /// 1. 窗口高度 = 屏幕可见区高度 × 90%
    /// 2. 此高度下截图能显示的宽度 = (高度 - chrome - canvas padding) × 截图长宽比
    /// 3. 窗口宽度 = max(截图显示宽度 + canvas padding, 760pt)
    /// 4. 居中显示在截图所在屏
    ///
    /// chromeHeight 是工具栏 + 分隔线 + footer 的估算高度。改 EditorView 排版
    /// 后必须同步更新此值。当前布局实测约 98pt：
    ///   - EditorToolbar:      padding 10+10 + content ~26 + divider 1 = 47
    ///   - footer:             padding 10+10 + button height ~30 + divider 1 = 51
    /// minSize = 760 × 760，工具栏自然下限。
    private static let chromeHeight: CGFloat = 98
    private static let canvasPadding: CGFloat = 32  // EditorView.canvas .padding(16) × 2

    private static func configureSize(
        window: NSWindow,
        displayID: CGDirectDisplayID,
        image: CaptureImage
    ) {
        let screen = NSScreen.screens.first { ns in
            let id = ns.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return id == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first

        let visible = screen?.visibleFrame ?? CGRect(x: 100, y: 100, width: 1280, height: 800)
        let height = visible.height * 0.9

        // 反算图像在 90% 高度窗口里能显示的宽度。
        let canvasInnerHeight = max(height - chromeHeight - canvasPadding, 1)
        let aspectRatio = image.size.height > 0
            ? image.size.width / image.size.height
            : 1
        let imageDisplayWidth = canvasInnerHeight * aspectRatio

        let width = max(imageDisplayWidth + canvasPadding, 760)
        let x = visible.midX - width / 2
        let y = visible.midY - height / 2
        window.setFrame(CGRect(x: x, y: y, width: width, height: height), display: false)
        // minSize 由 NSHostingController.sizingOptions = [.minSize] 自动管理：
        // SwiftUI 视图的 .frame(minWidth: 760, minHeight: 760) 会被同步推到
        // window.contentMinSize，不需要在此手动赋值。两层独立赋值会在临界值抖动。
    }
}
