//
//  OnboardingComponents.swift
//  Mio
//
//  Onboarding 三页共用的视觉积木。改外观就来这里；改时序就去
//  OnboardingPages.swift；改外壳骨架就去 OnboardingWindow.swift。
//
//  共享件：
//    · FakeDesktop          浅色"假桌面"（3 个假窗口固定排列）
//    · FakeWindowChrome     单个假窗口（红绿灯 + 标题栏 + 内容色块）
//    · CaptureDimOverlay    截图时的遮罩 + 透亮选区
//    · CopiedToast          "⌘C 已复制" 顶部居中提示
//    · CursorMark           光标小三角
//    · OnboardingPageShell  共用页面骨架：上动画区 + 下文字区
//

import SwiftUI

// MARK: - Page shell

/// 三页都用的版面骨架：上方动画大头，下方标题 + 副标题 + 可选行动区。
///
/// title / subtitle 用 LocalizedStringKey,xcstrings 提取器会自动收集到
/// Localizable.xcstrings,翻译后随 SwiftUI Bundle 动态生效。
struct OnboardingPageShell<Stage: View, Action: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let stage: () -> Stage
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: 18) {
            // 动画区：占满剩余高度。左右边距与底部按钮到窗口侧边一致。
            stage()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: OnboardingLayout.stageCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: OnboardingLayout.stageCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .padding(.horizontal, 8)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)

            action()
        }
    }
}

/// 无 action 区的便捷重载，保持既有调用兼容。
extension OnboardingPageShell where Action == EmptyView {
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder stage: @escaping () -> Stage
    ) {
        self.init(title: title, subtitle: subtitle, stage: stage, action: { EmptyView() })
    }
}

// MARK: - Fake desktop

/// "假桌面"：左、中、右三个假应用窗口，固定排列。三页共用，让 onboarding
/// 像同一个故事的三个时刻，而不是三张孤立海报。
///
/// 浅色 / 暗色双形态:跟随 environment colorScheme,与 onboarding 窗口
/// 当前外观一致;暗色下用标准 Apple 中性灰桌面色 #2A2A2A → #1F1F1F
/// 渐变,与画框页 #1E1E1E 假窗口背景同档,整套 onboarding 是同一调性。
struct FakeDesktop: View {
    /// 高亮哪一个窗口（用于 F5 第二段：hover 抬升 + 描边）。
    var highlightedWindow: Int? = nil
    /// 整个桌面闪一下（用于 F6：全屏截图的"咔"）。
    var flashAlpha: Double = 0

    @Environment(\.colorScheme) private var colorScheme

    private var wallpaperColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.165, green: 0.165, blue: 0.165),   // #2A2A2A
                Color(red: 0.122, green: 0.122, blue: 0.122)    // #1F1F1F
            ]
        } else {
            return [Color(white: 0.96), Color(white: 0.92)]
        }
    }

    private var windowShadowAlpha: Double {
        // 暗色下硬阴影不可见,改用极轻的"压下去"投影 + 主要靠描边出层级。
        colorScheme == .dark ? 0.28 : 0.10
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 桌面壁纸
                LinearGradient(
                    colors: wallpaperColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // 三个假窗口的层叠：左中右，深度感靠尺寸差与轻微阴影。
                let unit = geo.size.width / 100

                FakeWindowChrome(accent: .blue, contentLines: 4)
                    .frame(width: unit * 38, height: unit * 26)
                    .shadow(color: .black.opacity(windowShadowAlpha), radius: 12, x: 0, y: 4)
                    .scaleEffect(highlightedWindow == 0 ? 1.03 : 1.0)
                    .overlay {
                        if highlightedWindow == 0 { highlightOverlay() }
                    }
                    .position(x: unit * 24, y: unit * 28)
                    .animation(.smooth(duration: 0.25), value: highlightedWindow)

                FakeWindowChrome(accent: .orange, contentLines: 5)
                    .frame(width: unit * 42, height: unit * 30)
                    .shadow(color: .black.opacity(windowShadowAlpha + 0.02), radius: 16, x: 0, y: 6)
                    .scaleEffect(highlightedWindow == 1 ? 1.03 : 1.0)
                    .overlay {
                        if highlightedWindow == 1 { highlightOverlay() }
                    }
                    .position(x: unit * 56, y: unit * 38)
                    .animation(.smooth(duration: 0.25), value: highlightedWindow)

                FakeWindowChrome(accent: .green, contentLines: 3)
                    .frame(width: unit * 30, height: unit * 22)
                    .shadow(color: .black.opacity(windowShadowAlpha), radius: 10, x: 0, y: 4)
                    .scaleEffect(highlightedWindow == 2 ? 1.03 : 1.0)
                    .overlay {
                        if highlightedWindow == 2 { highlightOverlay() }
                    }
                    .position(x: unit * 80, y: unit * 60)
                    .animation(.smooth(duration: 0.25), value: highlightedWindow)

                // 全屏闪白（F6 用）
                // 暗色下也用白色——"咔"瞬间是相机闪光的视觉记忆,不分主题。
                Color.white
                    .opacity(flashAlpha)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func highlightOverlay() -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .blur(radius: 0.5)
    }
}

/// 一个假应用窗口：圆角 + 三个红绿灯 + 标题占位 + 几行内容 line。
/// 浅色 / 暗色双形态,与 P4 画框页内嵌假窗口同色谱:
///   · 浅色:标题栏 #FAFAFA / 内容 #FFFFFF
///   · 暗色:标题栏 #2A2A2A / 内容 #1E1E1E
struct FakeWindowChrome: View {
    let accent: Color
    let contentLines: Int

    @Environment(\.colorScheme) private var colorScheme

    private var titleBarColor: Color {
        colorScheme == .dark
            ? Color(red: 0.165, green: 0.165, blue: 0.165)   // #2A2A2A
            : Color.white
    }

    private var contentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.118, green: 0.118, blue: 0.118)   // #1E1E1E
            : Color(white: 0.99)
    }

    private var placeholderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.10)
    }

    private var strokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
    }

    var body: some View {
        VStack(spacing: 0) {
            // titlebar
            HStack(spacing: 6) {
                Circle().fill(Color(red: 0.99, green: 0.36, blue: 0.36)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 1.0, green: 0.76, blue: 0.18)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.32, green: 0.78, blue: 0.32)).frame(width: 10, height: 10)
                Spacer()
                RoundedRectangle(cornerRadius: 3).fill(placeholderColor).frame(width: 60, height: 6)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(titleBarColor)

            // content
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.7)).frame(height: 10).frame(maxWidth: 80)
                ForEach(0..<contentLines, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(placeholderColor)
                        .frame(height: 6)
                        .frame(maxWidth: i.isMultiple(of: 2) ? .infinity : 200)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(contentColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 0.5)
        }
    }
}

// MARK: - Hotkey capsule

/// F5 / F7 / F6 用的同一种胶囊：浅灰底 + 黑字 + 圆角。
struct HotkeyCapsule: View {
    let label: String
    var pressed: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.black.opacity(0.82))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(pressed ? Color(white: 0.78) : Color(white: 0.93))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(pressed ? 0.0 : 0.08), radius: pressed ? 0 : 2, y: pressed ? 0 : 1)
            .scaleEffect(pressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: - Capture mask

/// 截图遮罩。传入 cutout 时，遮罩会在目标区域挖空，让选区或窗口
/// 像系统截图模式一样从暗色遮罩中透亮出来。
struct CaptureDimOverlay: View {
    var cutout: CGRect?
    var opacity: Double = 0.20
    var cornerRadius: CGFloat = 8

    var body: some View {
        CaptureDimShape(
            cutout: cutout ?? .zero,
            hasCutout: cutout == nil ? 0 : 1,
            cornerRadius: cornerRadius
        )
        .fill(Color.black.opacity(opacity), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }
}

/// `nonisolated`：纯几何计算，无线程归属。项目开了
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不标注就会被推断为
/// `@MainActor`，而 `Shape` / `Animatable` 的要求（`path(in:)`、
/// `animatableData`）是 nonisolated 且继承 `SendableMetatype`，两个承诺
/// 冲突 → Swift 6.4 报 `#ConformanceIsolation` error。标在类型上一次覆盖
/// 全部要求（`Shape: Animatable`，此处有两个 witness）。
private nonisolated struct CaptureDimShape: Shape {
    var cutout: CGRect
    var hasCutout: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(cutout.origin.x, cutout.origin.y),
                AnimatablePair(cutout.size.width, cutout.size.height)
            )
        }
        set {
            cutout.origin.x = newValue.first.first
            cutout.origin.y = newValue.first.second
            cutout.size.width = newValue.second.first
            cutout.size.height = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)

        if hasCutout > 0.5 {
            path.addRoundedRect(
                in: cutout,
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )
        }

        return path
    }
}

// MARK: - Copied toast

/// "⌘C 已复制" 提示。三页共用同一种样式 + 同一个落点（动画区顶部居中）——
/// 形成视觉记忆。
struct CopiedToast: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("onboarding.copied")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

// MARK: - Cursor

/// 简化的鼠标光标（一个倾斜三角 + 描边）。跟随 colorScheme:
/// 浅色用黑光标 + 白描边,暗色用白光标 + 黑描边——与 macOS 系统光标
/// 在两种外观下的视觉记忆一致。
struct CursorMark: View {
    @Environment(\.colorScheme) private var colorScheme

    private var bodyColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var ringColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(bodyColor)
            .shadow(color: ringColor.opacity(0.7), radius: 0, y: 1)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

// MARK: - Click ripple

/// 鼠标点击时的轻量涟漪反馈。用于 onboarding 动画里的释放选区和点击窗口。
struct ClickRipple: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(expanded ? 0 : 0.42), lineWidth: 1.6)
                .frame(width: 18, height: 18)
                .scaleEffect(expanded ? 2.2 : 0.35)

            Circle()
                .fill(Color.accentColor.opacity(expanded ? 0 : 0.18))
                .frame(width: 10, height: 10)
                .scaleEffect(expanded ? 1.35 : 0.45)
        }
        .allowsHitTesting(false)
        .task {
            expanded = false
            withAnimation(.easeOut(duration: 0.9)) {
                expanded = true
            }
        }
    }
}

// MARK: - Selection rectangle

/// F5 第一段用的"选区矩形"：蓝色描边 + 半透明填充。
struct SelectionRect: View {
    var glow: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.accentColor.opacity(glow ? 0.18 : 0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
            .shadow(color: glow ? Color.accentColor.opacity(0.4) : .clear, radius: glow ? 8 : 0)
            .animation(.smooth(duration: 0.25), value: glow)
    }
}
