//
//  OnboardingWindow.swift
//  Mio
//
//  Onboarding 引导：3 页相同骨架，介绍 F5 / F7 / F6 三种截图方式。
//
//  本文件 = 入口与"外壳"
//    · OnboardingView            根容器：progress dots + 翻页 + 底栏（返回 / 下一步）
//    · ProgressDots              顶部 3 圆点指示
//    · OnboardingFooter          底部按钮行
//
//  动画在 OnboardingPages.swift；共享组件（假桌面 / F 键胶囊 / 已复制提示
//  / 光标）在 OnboardingComponents.swift。
//
//  Window scene 由 MioApp.swift 注册（id = "onboarding"），通过
//  openWindow(id: "onboarding") 打开，dismissWindow(id:) 关闭。
//
//  设计取舍：
//    - 不持有 NSWindowController：menu-bar accessory app 里 SwiftUI Window
//      scene + dismissWindow 是最稳路径（旧版 NSWindowController 子类
//      化在某些 macOS 版本下窗口不可见，已弃用）。
//    - 固定尺寸 720×560：3 页内容用同一块画布，避免翻页时 reflow。
//    - 保留当前系统原生 Window chrome：窗口圆角、阴影、背景材质、焦点
//      和拖拽行为由系统负责；macOS 26 自然呈现新版外观，本视图只定义布局。
//    - 展示路径：view 出现即写入本版本戳；用户点 X 关闭也不重复打扰。
//    - 关闭路径：底栏最后一页的"开始使用"会调用 dismissWindow(id:)。
//

import SwiftUI

// MARK: - Constants

enum OnboardingLayout {
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 560
    static let pageCount: Int = 5

    /// 动画区底色与卡片描边都基于这个圆角，与下方文字区视觉对齐。
    static let stageCornerRadius: CGFloat = 18
}

// MARK: - Root view

struct OnboardingView: View {
    /// 关闭回调。AppDelegate 路径下由 OnboardingPresenter 注入,
    /// 触发 NSWindow.orderOut。环境里没注入时(如 #Preview)走兜底
    /// dismiss-window,保证两条路径都可用。
    let onClose: (() -> Void)?

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pageIndex: Int = 0

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: pageIndex, total: OnboardingLayout.pageCount)
                .padding(.top, 22)        // 顶部呼吸（HIG ≥ 20）
                .padding(.bottom, 14)     // 进度点 ↔ 动画区

            // 翻页区。每个 page view 自己负责动画 + 文字 + 高度铺满。
            // 用 ZStack + .opacity 交叉淡入淡出，不用 TabView（避免横向滑动
            // 让用户误以为可以左右拖）。
            // 翻页区。每个 page view 自己负责动画 + 文字 + 高度铺满。
            // 用条件渲染 + transition 做交叉淡入，而不是把三页同时挂载
            // 用 opacity 切。后者让所有 page 永远 onAppear，内含的
            // OnboardingHotkeyButton 录入态切页时不会 onDisappear，导致
            // NSEvent monitor 泄漏，HotKeyManager.setRecordingHotKey(true)
            // 永远不被复位，全局 hotkey 永久失效（严重 regression）。
            ZStack {
                page(pageIndex)
                    .id(pageIndex)
                    .transition(.opacity)
            }
            .animation(.smooth(duration: 0.35), value: pageIndex)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OnboardingFooter(
                pageIndex: $pageIndex,
                onFinish: close
            )
            .padding(.horizontal, 8)
            .padding(.top, 24)        // 副标题 ↔ 按钮（HIG: 副标题不该贴按钮）
            .padding(.bottom, 8)      // 左右与底边等距，贴近窗口底角
        }
        .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        .onAppear {
            OnboardingPresenter.markPresented()
        }
        // 不在 SwiftUI 这边自画窗口背景——onboarding 窗口由 OnboardingPresenter
        // 用 NSWindow 承载,默认 .windowBackgroundColor 已经给出 macOS 标准窗口
        // 背景。containerBackground(for: .window) 在 NSHostingController 路径下
        // 是 no-op,留着会让人误以为有效。
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0: OnboardingPageF5()
        case 1: OnboardingPageF7()
        case 2: OnboardingPageF6()
        case 3: OnboardingPageFrame()
        default: OnboardingPageStorage()
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismissWindow(id: "onboarding")
        }
    }
}

// MARK: - Progress dots

struct ProgressDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index == current
                          ? Color.primary.opacity(0.85)
                          : Color.primary.opacity(0.18))
                    .frame(width: index == current ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current)
            }
        }
        .padding(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressLabel)
    }

    private var progressLabel: String {
        let format = NSLocalizedString(
            "onboarding.progress.label",
            comment: "VoiceOver page progress label, e.g. 'Page 2 of 5'"
        )
        return String(format: format, current + 1, total)
    }
}

// MARK: - Footer

/// Onboarding 底部按钮行。macOS 26 使用液态玻璃 `.glass` /
/// `.glassProminent`；macOS 15–25 使用系统 `.bordered` /
/// `.borderedProminent`，保留相同的按钮形状与布局。
///
/// "跳过"按钮仅在带有"跳过=显式拒绝"语义的页面显示（如画框页：
/// 跳过 = 不启用画框）。点击下一步 = 默认接受当前页的引导动作，
/// 点击跳过 = 显式撤回该动作。两个按钮都会推进到下一页。
///
/// 主操作按钮的可用性由当前页判定（如存储页要求用户做出明确选择）——
/// 这把"不做选择就 finish 导致 silent fail"的路径彻底封死。
struct OnboardingFooter: View {
    @Binding var pageIndex: Int
    let onFinish: () -> Void

    @EnvironmentObject var capture: CaptureSettings

    private var skipBehavior: SkipBehavior? {
        switch pageIndex {
        case 3: return .frame
        default: return nil
        }
    }

    private enum SkipBehavior {
        case frame
    }

    /// 主操作按钮是否可用。存储页（pageIndex == 4）要求用户做出明确
    /// 选择（仅剪贴板 / 保存到有效文件夹之一）才允许 finish；其他页
    /// 始终可用（页面本身有默认值）。
    private var primaryEnabled: Bool {
        switch pageIndex {
        case 4:
            if capture.saveToFile {
                return capture.hasValidSaveFolder
            } else {
                return true   // 仅剪贴板,无需路径
            }
        default:
            return true
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // 返回：左下角圆形玻璃按钮。用系统 chevron 保持圆按钮语义清晰，
            // 不把文字硬塞进圆形里。
            Button {
                withAnimation(.smooth(duration: 0.35)) { pageIndex -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .onboardingSecondaryButtonStyle()
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .clipShape(Circle())
            .accessibilityLabel(Text("onboarding.button.back"))
            .disabled(pageIndex == 0)

            // 跳过：无边框次级按钮。仅在带"跳过 = 显式拒绝"语义的页面显示。
            // 与"下一步"对照：下一步 = 接受引导（启用画框/选择默认存储等），
            // 跳过 = 显式拒绝（关闭画框/不保存到文件等）。
            if let behavior = skipBehavior {
                Button {
                    handleSkip(behavior)
                } label: {
                    Text("onboarding.button.skip")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 32)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("onboarding.button.skip_page"))
            }

            Spacer()

            Button {
                if let behavior = skipBehavior {
                    handleAccept(behavior)
                }
                if pageIndex < OnboardingLayout.pageCount - 1 {
                    withAnimation(.smooth(duration: 0.35)) { pageIndex += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(pageIndex == OnboardingLayout.pageCount - 1
                     ? "onboarding.button.start"
                     : "onboarding.button.next")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 96, minHeight: 32)
            }
            .onboardingPrimaryButtonStyle()
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryEnabled)
        }
    }

    private func handleAccept(_ behavior: SkipBehavior) {
        switch behavior {
        case .frame:
            capture.captureFrameEnabled = true
        }
    }

    private func handleSkip(_ behavior: SkipBehavior) {
        switch behavior {
        case .frame:
            capture.captureFrameEnabled = false
        }
        withAnimation(.smooth(duration: 0.35)) { pageIndex += 1 }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
        .environmentObject(AppSettings.shared.hotkey)
}
