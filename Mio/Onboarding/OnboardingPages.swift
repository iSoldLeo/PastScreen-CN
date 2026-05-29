//
//  OnboardingPages.swift
//  Mio
//
//  三页 onboarding 的具体内容 + 动画时序。每页 = 一个 View struct，
//  用 OnboardingPageShell 套同一套版面骨架。
//
//  动画策略：每页内有个 phase 状态机（0..N），用 Task 驱动 phase 推进，
//  动画用 SwiftUI .animation(.smooth, value: phase) 完成。整体 ~6 秒
//  循环（参考你的设计稿）。
//
//  动画在 onAppear 启动，view 从 ZStack 切到 opacity=0 时通过 task 自然
//  cancel——不需要手动停。
//
//  调试动画时序：把 phase 临时设成 @State + Stepper，逐 step 跳。
//

import SwiftUI

// MARK: - Page 1: F5 area + window capture

struct OnboardingPageF5: View {
    @EnvironmentObject var hotkeySettings: HotKeySettings
    @State private var phase: Int = 0
    // phase:
    //   0  桌面空闲
    //   1  快捷键触发，截图遮罩浮现
    //   2  光标到拖拽起点，选区刚开始
    //   3  拖出选区，选区区域从遮罩中透亮
    //   4  松开确认，选区原地高亮并出现点击涟漪
    //   5  已复制
    //   6  第二段开始，遮罩重新浮现
    //   7  光标移向目标窗口
    //   8  目标窗口 hover，高亮于遮罩之上
    //   9  点击确认，窗口原地按压并出现点击涟漪
    //   10 窗口原地确认
    //   11 已复制，暂停后循环

    var body: some View {
        OnboardingPageShell(
            title: "onboarding.f5.title",
            subtitle: "onboarding.f5.subtitle"
        ) {
            stage
        } action: {
            OnboardingHotkeyButton(hotkey: $hotkeySettings.windowCaptureHotkey)
        }
        .task {
            await runLoop()
        }
    }

    @ViewBuilder
    private var stage: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height

            ZStack {
                FakeDesktop(highlightedWindow: (8...10).contains(phase) ? 1 : nil)

                if shouldShowCaptureMask {
                    CaptureDimOverlay(cutout: maskCutout(W: W, H: H), opacity: 0.20)
                        .transition(.opacity)
                }

                // 区域截图：按下快捷键后先出遮罩，再从遮罩中拉出更亮的选区。
                if shouldShowSelection {
                    let rect = selectionFrame(W: W, H: H)
                    SelectionRect(glow: phase == 4)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                }

                // 窗口截图：点击后只做原地按压确认，不再飞向顶部提示。
                if shouldShowWindowGhost {
                    let rect = windowGhostFrame(W: W)
                    FakeWindowChrome(accent: .orange, contentLines: 5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .scaleEffect(phase == 9 ? 0.97 : 1)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                        .transition(.opacity)
                }

                if phase == 4 || phase == 9 {
                    ClickRipple()
                        .position(cursorTipPosition(W: W, H: H))
                        .transition(.opacity)
                }

                // 光标位置（按 phase 移动）
                CursorMark()
                    // CursorMark 的 frame 原点附近才是箭头尖端；这里把尖端对齐到真实点击点。
                    .position(cursorTipPosition(W: W, H: H))
                    .offset(x: 12, y: 12)
                    .animation(.smooth(duration: 1.5), value: phase)
                    .opacity(shouldShowCursor ? 1 : 0)

                // 已复制 toast：动画窗口顶部居中，phase 2 之后
                if phase == 5 || phase == 11 {
                    CopiedToast()
                        .position(x: W * 0.5, y: 30)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 1.0), value: phase)
        }
    }

    private var shouldShowCaptureMask: Bool {
        (1...4).contains(phase) || (6...10).contains(phase)
    }

    private var shouldShowSelection: Bool {
        (2...4).contains(phase)
    }

    private var shouldShowWindowGhost: Bool {
        phase == 9 || phase == 10
    }

    private var shouldShowCursor: Bool {
        (2...4).contains(phase) || (7...10).contains(phase)
    }

    private func maskCutout(W: CGFloat, H: CGFloat) -> CGRect? {
        if shouldShowSelection {
            selectionFrame(W: W, H: H)
        } else if (8...10).contains(phase) {
            targetWindowFrame(W: W).insetBy(dx: -8, dy: -8)
        } else {
            nil
        }
    }

    private func selectionFrame(W: CGFloat, H: CGFloat) -> CGRect {
        let start = selectionStart(W: W, H: H)
        let end = selectionEnd(W: W, H: H)
        let final = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        switch phase {
        case 2:
            return CGRect(x: start.x, y: start.y, width: 8, height: 8)
        default:
            return final
        }
    }

    private func selectionStart(W: CGFloat, H: CGFloat) -> CGPoint {
        CGPoint(x: W * 0.24, y: H * 0.30)
    }

    private func selectionEnd(W: CGFloat, H: CGFloat) -> CGPoint {
        CGPoint(x: W * 0.52, y: H * 0.58)
    }

    private func targetWindowFrame(W: CGFloat) -> CGRect {
        let unit = W / 100
        return CGRect(
            x: unit * 56 - unit * 42 / 2,
            y: unit * 38 - unit * 30 / 2,
            width: unit * 42,
            height: unit * 30
        )
    }

    private func windowGhostFrame(W: CGFloat) -> CGRect {
        return targetWindowFrame(W: W)
    }

    private func windowClickPoint(W: CGFloat) -> CGPoint {
        let target = targetWindowFrame(W: W)
        return CGPoint(x: target.midX, y: target.minY + target.height * 0.42)
    }

    private func cursorTipPosition(W: CGFloat, H: CGFloat) -> CGPoint {
        switch phase {
        case 0: return CGPoint(x: W + 20, y: H + 20)        // 屏外
        case 1: return CGPoint(x: W + 20, y: H + 20)
        case 2: return selectionStart(W: W, H: H)            // 拖拽起点，箭头尖端对齐
        case 3: return selectionEnd(W: W, H: H)              // 拖拽终点，箭头尖端对齐
        case 4: return selectionEnd(W: W, H: H)
        case 7: return CGPoint(x: W * 0.40, y: H * 0.62)
        case 8: return windowClickPoint(W: W)                // 用目标窗口真实 frame 定位
        case 9: return windowClickPoint(W: W)
        case 10: return windowClickPoint(W: W)
        default: return CGPoint(x: W + 20, y: H + 20)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            phase = 0
            try? await Task.sleep(for: .milliseconds(800))
            phase = 1
            try? await Task.sleep(for: .milliseconds(900))
            phase = 2
            // 光标移动到拖拽起点需要 1.5s。这里必须长于光标动画，
            // 否则还没落到起点，选区就已经开始被拉大了。
            try? await Task.sleep(for: .milliseconds(1700))
            phase = 3
            try? await Task.sleep(for: .milliseconds(1700))
            phase = 4
            try? await Task.sleep(for: .milliseconds(1040))
            phase = 5
            try? await Task.sleep(for: .milliseconds(1900))
            phase = 6
            try? await Task.sleep(for: .milliseconds(840))
            phase = 7
            try? await Task.sleep(for: .milliseconds(1240))
            phase = 8
            try? await Task.sleep(for: .milliseconds(1240))
            phase = 9
            try? await Task.sleep(for: .milliseconds(360))
            phase = 10
            try? await Task.sleep(for: .milliseconds(1040))
            phase = 11
            try? await Task.sleep(for: .milliseconds(2600))
        }
    }
}

// MARK: - Page 2: F7 advanced (with editor)

struct OnboardingPageF7: View {
    @EnvironmentObject var hotkeySettings: HotKeySettings
    @State private var phase: Int = 0
    // phase:
    //   0 桌面
    //   1 拖出选区
    //   2 选区"撕"出来变成编辑器壳
    //   3 编辑器内画一个红色矩形（fly-draw）
    //   4 画一个箭头
    //   5 完成 → 已复制 toast
    //   6 暂停后回到 0

    var body: some View {
        OnboardingPageShell(
            title: "onboarding.f7.title",
            subtitle: "onboarding.f7.subtitle"
        ) {
            stage
        } action: {
            OnboardingHotkeyButton(hotkey: $hotkeySettings.advancedWindowCaptureHotkey)
        }
        .task { await runLoop() }
    }

    @ViewBuilder
    private var stage: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let inEditor = phase >= 2 && phase != 6

            ZStack {
                if !inEditor {
                    FakeDesktop()
                        .transition(.opacity)
                }

                if phase == 1 {
                    SelectionRect(glow: false)
                        .frame(width: W * 0.45, height: H * 0.50)
                        .position(x: W * 0.45, y: H * 0.50)
                        .transition(.opacity)
                }

                if inEditor {
                    FakeEditor(phase: phase, width: W * 0.78, height: H * 0.72)
                        .position(x: W * 0.5, y: H * 0.50)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                if phase == 5 {
                    CopiedToast()
                        .position(x: W * 0.5, y: 30)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.45), value: phase)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            phase = 0
            try? await Task.sleep(for: .milliseconds(500))
            phase = 1
            try? await Task.sleep(for: .milliseconds(900))
            phase = 2
            try? await Task.sleep(for: .milliseconds(700))
            phase = 3
            try? await Task.sleep(for: .milliseconds(800))
            phase = 4
            try? await Task.sleep(for: .milliseconds(900))
            phase = 5
            try? await Task.sleep(for: .milliseconds(1300))
            phase = 6
            try? await Task.sleep(for: .milliseconds(900))
        }
    }
}

/// F7 页内嵌的"假编辑器"窗口,跟随 colorScheme 适配亮/暗主题。
/// 标准 Apple 灰阶——浅色 #F7F7F7 toolbar / #FFFFFF canvas;
/// 暗色 #2A2A2A toolbar / #1E1E1E canvas,与 onboarding 其他假窗口同档。
private struct FakeEditor: View {
    let phase: Int
    let width: CGFloat
    let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    private var toolbarColor: Color {
        colorScheme == .dark
            ? Color(red: 0.165, green: 0.165, blue: 0.165)   // #2A2A2A
            : Color(white: 0.97)
    }

    private var canvasColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.118, green: 0.118, blue: 0.118),   // #1E1E1E
                Color(red: 0.094, green: 0.094, blue: 0.094)    // #181818
            ]
        } else {
            return [Color(white: 0.99), Color(white: 0.94)]
        }
    }

    private var strokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.10)
    }

    private var shadowAlpha: Double {
        colorScheme == .dark ? 0.36 : 0.12
    }

    var body: some View {
        VStack(spacing: 0) {
            // toolbar
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let icons = ["square", "circle", "arrow.up.right", "pencil", "rectangle.dashed", "textformat"]
                    Image(systemName: icons[i])
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill((i == 0 && phase == 3) || (i == 2 && phase >= 4)
                                      ? Color.accentColor.opacity(0.2)
                                      : Color.clear)
                        )
                        .foregroundStyle(.primary)
                }
                Spacer()
                Circle().fill(.red).frame(width: 12, height: 12)
                Circle().fill(.blue).frame(width: 12, height: 12)
                // 第三个色块跟随主题——暗色下纯黑会消失,改用主色调对比 swatch
                Circle().fill(colorScheme == .dark ? Color.white : Color.black).frame(width: 12, height: 12)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(toolbarColor)

            // canvas
            ZStack {
                // 占位"截到的图"
                LinearGradient(colors: canvasColors, startPoint: .top, endPoint: .bottom)

                // 红色矩形 (phase ≥ 3)
                if phase >= 3 {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.red, lineWidth: 3)
                        .frame(width: width * 0.32, height: height * 0.28)
                        .offset(x: -width * 0.12, y: -height * 0.05)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // 箭头 (phase ≥ 4)
                if phase >= 4 {
                    ArrowShape()
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: width * 0.30, height: height * 0.18)
                        .offset(x: width * 0.18, y: height * 0.10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .clipped()

            // footer
            HStack {
                Spacer()
                Text("完成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(phase == 5 ? Color.accentColor.opacity(0.7) : Color.accentColor)
                    )
                    .scaleEffect(phase == 5 ? 0.94 : 1.0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(toolbarColor)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(shadowAlpha), radius: 18, y: 6)
        .animation(.smooth(duration: 0.35), value: phase)
    }
}

/// 一个简单的箭头 path（用在 F7 的编辑器里）。
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let start = CGPoint(x: rect.minX, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)
        p.move(to: start)
        p.addLine(to: end)

        // arrow head
        let headLen: CGFloat = min(rect.width, rect.height) * 0.35
        let angle = atan2(end.y - start.y, end.x - start.x)
        let h1 = CGPoint(
            x: end.x - headLen * cos(angle - .pi / 7),
            y: end.y - headLen * sin(angle - .pi / 7)
        )
        let h2 = CGPoint(
            x: end.x - headLen * cos(angle + .pi / 7),
            y: end.y - headLen * sin(angle + .pi / 7)
        )
        p.move(to: end); p.addLine(to: h1)
        p.move(to: end); p.addLine(to: h2)
        return p
    }
}

// MARK: - Page 3: F6 fullscreen

struct OnboardingPageF6: View {
    @EnvironmentObject var hotkeySettings: HotKeySettings
    @State private var phase: Int = 0
    // phase:
    //   0 桌面
    //   1 按下：闪一下白
    //   2 已复制 toast
    //   3 暂停回循环

    var body: some View {
        OnboardingPageShell(
            title: "onboarding.f6.title",
            subtitle: "onboarding.f6.subtitle"
        ) {
            stage
        } action: {
            OnboardingHotkeyButton(hotkey: $hotkeySettings.fullScreenHotkey)
        }
        .task { await runLoop() }
    }

    @ViewBuilder
    private var stage: some View {
        GeometryReader { geo in
            let W = geo.size.width

            ZStack {
                FakeDesktop(flashAlpha: phase == 1 ? 0.85 : 0)
                    .animation(.easeOut(duration: 0.18), value: phase)

                if phase >= 2 {
                    CopiedToast()
                        .position(x: W * 0.5, y: 30)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.4), value: phase)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            phase = 0
            try? await Task.sleep(for: .milliseconds(700))
            phase = 1
            try? await Task.sleep(for: .milliseconds(280))
            phase = 2
            try? await Task.sleep(for: .milliseconds(2000))
            phase = 3
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}

// MARK: - Previews

#Preview("F5") {
    OnboardingPageF5()
        .environmentObject(AppSettings.shared.hotkey)
        .frame(width: 720, height: 480)
}
#Preview("F7") {
    OnboardingPageF7()
        .environmentObject(AppSettings.shared.hotkey)
        .frame(width: 720, height: 480)
}
#Preview("F6") {
    OnboardingPageF6()
        .environmentObject(AppSettings.shared.hotkey)
        .frame(width: 720, height: 480)
}
