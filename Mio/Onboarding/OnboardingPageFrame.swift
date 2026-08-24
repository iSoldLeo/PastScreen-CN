//
//  OnboardingPageFrame.swift
//  Mio
//
//  Onboarding 第 4 页：画框引导。
//
//  叙事策略：不弹"要不要开"的 toggle。直接给一张已经套好画框的预览图,
//  用户在下方输入框里改自己的署名,看着画框里的签名实时变化——这是
//  capture-frame-spec.md §1 "优雅到值得开" 的最快说服路径。
//
//  按钮契约（OnboardingFooter 中实现）：
//    · 下一步 = 接受引导 → captureFrameEnabled = true
//    · 跳过   = 显式拒绝 → captureFrameEnabled = false
//
//  视觉路径（关键决策）：复用正式 ImageProcessor actor，
//  不再用 SwiftUI 近似复刻。
//    1. ImageRenderer 把一张内嵌"假窗口截图"渲染成带 alpha 圆角的 CGImage
//       (一次性,@MainActor)
//    2. 包成 CaptureImage，提交 frame request 得到带画框的 CGImage
//       (squircle / halo / footer 全部走真渲染管线)
//    3. signature 改变 → 120ms debounce → 重合成 → Image(nsImage:) 显示
//    4. 跟随系统外观切 light/dark
//
//  为什么不用 SwiftUI 近似:用户对画框的视觉记忆来自最终 PNG 输出,
//  onboarding 里看到的与最终输出"几乎一样但不一样"会破坏说服力。
//  spec §3.7 暗示视觉规约即契约,onboarding 引导和真实输出之间的
//  视觉一致性是产品诚意。
//
//  重位图工作通过 actor hop 离开 MainActor；page 持有 debounce/render 两个
//  task handle 与 generation，换页或新请求都会取消旧工作。
//

import SwiftUI
import AppKit

// MARK: - Page

struct OnboardingPageFrame: View {
    let imageProcessor: ImageProcessor
    @EnvironmentObject var capture: CaptureSettings
    @Environment(\.colorScheme) private var colorScheme

    /// 一次性渲染好的源截图（含 alpha 圆角）。
    @State private var sourceImage: CGImage?
    /// 合成结果——实时跟随 signature / theme 变化。
    @State private var composedImage: NSImage?
    /// signature 变化的 debounce task；新输入到来时取消旧 task。
    @State private var debounceTask: Task<Void, Never>?
    /// Exactly one render operation belongs to this page instance.
    @State private var renderTask: Task<Void, Never>?
    @State private var renderGeneration: UInt64 = 0
    /// 上一次源图渲染时使用的 colorScheme。系统外观切换时需要重渲染源图。
    @State private var sourceColorScheme: ColorScheme?

    var body: some View {
        OnboardingPageShell(
            title: "onboarding.frame.title",
            subtitle: "onboarding.frame.subtitle"
        ) {
            FramePreviewStage(image: composedImage)
        } action: {
            FrameSignatureField(text: Binding(
                get: { capture.captureFrameCustomText },
                set: { capture.setCaptureFrameCustomText($0) }
            ))
        }
        .task {
            await initialRender()
        }
        .onChange(of: capture.captureFrameCustomText) { _, _ in
            scheduleRecompose()
        }
        .onChange(of: colorScheme) { _, _ in
            // 切换系统外观:源图(假窗口)和合成结果都要重做——
            // 假窗口本身按 colorScheme 切色,不重渲染会留浅色窗口贴在
            // 暗色画框上。
            sourceImage = renderFakeWindowImage(colorScheme: colorScheme)
            sourceColorScheme = colorScheme
            recompose()
        }
        .onChange(of: capture.captureFrameTheme) { _, _ in
            recompose()
        }
        .onDisappear {
            debounceTask?.cancel()
            renderGeneration &+= 1
            renderTask?.cancel()
            renderTask = nil
        }
    }

    // MARK: - Render pipeline

    /// 进页第一次：渲染源图 + 立即合成。
    @MainActor
    private func initialRender() async {
        if sourceImage == nil || sourceColorScheme != colorScheme {
            sourceImage = renderFakeWindowImage(colorScheme: colorScheme)
            sourceColorScheme = colorScheme
        }
        recompose()
    }

    /// 同步触发一次合成（不 debounce）——主题切换等"低频"场景用。
    @MainActor
    private func recompose() {
        guard let source = sourceImage else { return }
        guard let captureImage = try? CaptureImage(validating: source, scale: 2) else {
            composedImage = nil
            return
        }

        renderGeneration &+= 1
        let generation = renderGeneration
        let correlationID = UUID()
        let configuration = ResolvedFrameConfiguration(
            theme: resolvedTheme(),
            signature: capture.captureFrameCustomText
        )
        let processor = imageProcessor
        renderTask?.cancel()
        renderTask = Task(
            name: "mio.onboarding.frame.\(correlationID.uuidString)",
            priority: .userInitiated
        ) { @MainActor in
            do {
                let result = try await processor.prepareImage(
                    ImagePreparationRequest(
                        correlationID: correlationID,
                        source: captureImage,
                        crop: nil,
                        frame: .apply(configuration)
                    )
                )
                guard !Task.isCancelled, renderGeneration == generation else { return }
                composedImage = NSImage(cgImage: result.cgImage, size: result.size)
                renderTask = nil
            } catch {
                guard renderGeneration == generation else { return }
                composedImage = nil
                renderTask = nil
            }
        }
    }

    /// 用户在输入框打字时:120ms debounce 后再合成,避免逐字符合成抖动。
    @MainActor
    private func scheduleRecompose() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            recompose()
        }
    }

    /// `.auto` 主题在 onboarding 里跟随当前系统外观——与 spec §4.3
    /// "渲染时绑定 NSAppearance" 的语义一致;这里用 SwiftUI colorScheme
    /// 作为 NSApp.effectiveAppearance 的代理。
    private func resolvedTheme() -> ResolvedFrameTheme {
        switch capture.captureFrameTheme {
        case .alwaysLight: return .light
        case .alwaysDark:  return .dark
        case .auto:        return colorScheme == .dark ? .dark : .light
        }
    }

    /// 用 ImageRenderer 把 SwiftUI 假窗口渲染成 @2x 带 alpha 圆角的 CGImage。
    /// 这是 onboarding 合成管线的"源截图",对应真实截图路径里 SCK 抓出来的
    /// `desktopIndependentWindow` 透明背景图。
    ///
    /// 假窗口的明暗跟随当前系统外观——暗色模式下显示暗色窗口,与画框
    /// 暗色版协调;不会出现"暗色画框包浅色窗口"的视觉违和。
    @MainActor
    private func renderFakeWindowImage(colorScheme: ColorScheme) -> CGImage? {
        let content = FakeWindowSample()
            .environment(\.colorScheme, colorScheme)
            .frame(
                width: FakeWindowSampleSize.point.width,
                height: FakeWindowSampleSize.point.height
            )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

// MARK: - Sample window content

private enum FakeWindowSampleSize {
    /// 假窗口的 point 尺寸。比例约 16:10,与 spec §3.6.1 验证过的
    /// "中等窗口"（Screen-30 1840×872）相近,经过 padding 28/28/28/64
    /// 包裹后 stage 视觉舒服。
    static let point = CGSize(width: 600, height: 376)
}

/// 一个干净的"假应用窗口"内容(SwiftUI 渲染版),专门给 onboarding
/// 的 ImageRenderer 用。形态参考 macOS 26 应用:浅灰/深灰标题栏 + 红绿灯
/// + 内容占位。圆角 20pt(macOS 26 标准),alpha 通道由 clipShape 提供
/// ——对应 FrameRenderer.detectInnerCornerRadius 在 alpha 列上扫到的
/// 像素半径,合成时外圆角自动 = 20 + 12 = 32,与 spec outer = inner+12
/// 同心策略一致。
///
/// 浅色 / 暗色双形态:跟随 environment colorScheme。颜色取 Apple 系统
/// 标准灰阶:
///   · 浅色:标题栏 #FAFAFA,内容 #FFFFFF,占位 black 10%
///   · 暗色:标题栏 #2A2A2A,内容 #1E1E1E,占位 white 12%
/// 暗色窗口背景 #1E1E1E 与画框暗色 #1C1C1E 形成 ~1 阶差,
/// 让窗口"压"在画框上有微弱层级感而不是溶在一起。
private struct FakeWindowSample: View {
    @Environment(\.colorScheme) private var colorScheme

    private var titleBarColor: Color {
        colorScheme == .dark
            ? Color(red: 0.165, green: 0.165, blue: 0.165)   // #2A2A2A
            : Color(red: 0.980, green: 0.980, blue: 0.980)   // #FAFAFA
    }

    private var contentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.118, green: 0.118, blue: 0.118)   // #1E1E1E
            : Color.white
    }

    private var placeholderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.10)
    }

    private var titleBarSeparator: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.05)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Circle().fill(Color(red: 0.99, green: 0.36, blue: 0.36)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1.0, green: 0.76, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.32, green: 0.78, blue: 0.32)).frame(width: 12, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 4).fill(placeholderColor).frame(width: 92, height: 8)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(titleBarColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(titleBarSeparator)
                    .frame(height: 0.5)
            }

            // 内容
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.36, green: 0.62, blue: 0.96), Color(red: 0.34, green: 0.56, blue: 0.94)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: 200, height: 14)

                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(placeholderColor)
                        .frame(height: 8)
                        .frame(maxWidth: i.isMultiple(of: 2) ? .infinity : 360, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(contentColor)
        }
        // 20pt 内圆角:macOS 26 标准应用窗口圆角。
        // FrameRenderer.detectInnerCornerRadius 沿左上 x=0 列扫到的像素 y
        // 就是这个值的 px 表示(20pt × scale=2 = 40px),除回 scale 得 20pt。
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Preview stage

/// 画框预览动画区。展示正式 ImageProcessor 的真实输出。
private struct FramePreviewStage: View {
    let image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // stage 背景:暗色版用稍暗的中性背景突出白光晕;浅色版用浅灰
                // 让卡片柔阴影有去处。颜色靠 SwiftUI 自适应。
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(20)
                        .transition(.opacity)
                } else {
                    // 首次合成完成前:轻量占位避免布局抖动
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.smooth(duration: 0.18), value: image)
        }
    }
}

// MARK: - Signature input

/// 签名输入框。视觉位置与 P1–P3 的快捷键按钮一致——副标题下方居中。
private struct FrameSignatureField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "signature")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("onboarding.frame.signature.placeholder", text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .default))
                .frame(minWidth: 220)

            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(text.isEmpty ? 0 : 1)
            .disabled(text.isEmpty)
            .help(Text("onboarding.frame.signature.clear"))
            .accessibilityLabel(Text("onboarding.frame.signature.clear"))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .frame(maxWidth: 360)
    }
}
