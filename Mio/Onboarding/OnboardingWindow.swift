//
//  OnboardingWindow.swift
//  Mio
//
//  Onboarding 引导：6 页（权限 / F5 / F7 / F6 / 画框 / 存储）；前三个截图页共用相同骨架。
//
//  本文件 = 入口与"外壳"
//    · OnboardingView            根容器：progress dots + 翻页 + 底栏（返回 / 下一步）
//    · ProgressDots              顶部页数圆点指示
//    · OnboardingFooter          底部按钮行
//
//  动画在 OnboardingPages.swift；共享组件（假桌面 / F 键胶囊 / 已复制提示
//  / 光标）在 OnboardingComponents.swift。
//
//  设计取舍：
//    - OnboardingPresenter 是唯一 NSWindow/NSHostingController 构造路径；
//      OnboardingView 必须由 host 注入明确关闭动作，不保留 SwiftUI
//      Window scene 或 dismissWindow fallback。
//    - 固定尺寸 720×560：3 页内容用同一块画布，避免翻页时 reflow。
//    - 保留 macOS 26 原生 Window chrome：窗口圆角、阴影、背景材质、焦点
//      和拖拽行为由系统负责；本视图只定义内容布局。
//    - 完成路径：仅最后一页的"开始使用"（host onClose → end(.finished)）写本
//      版本戳；view 出现、翻页、点 X 关闭都不写，未完成不误判为已完成。
//    - 关闭路径：底栏最后一页的"开始使用"只调用 host 注入的 onClose。
//

import SwiftUI

// MARK: - Constants

enum OnboardingLayout {
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 560
    static let pageCount: Int = 6

    /// 动画区底色与卡片描边都基于这个圆角，与下方文字区视觉对齐。
    static let stageCornerRadius: CGFloat = 18
}

// MARK: - Root view

struct OnboardingView: View {
    /// 关闭回调由唯一的 AppKit host 显式注入。
    let onClose: () -> Void
    let shortcutFormatter: ShortcutLabelFormatter
    let imageProcessor: ImageProcessor
    let permissionManager: PermissionManager
    let openScreenRecordingSettings: @MainActor () -> Result<Void, SystemSettingsOpenFailure>
    @EnvironmentObject private var shortcutService: GlobalShortcutService
    @State private var pageIndex: Int = 0
    @State private var permissionRequestedOnce = false
    @State private var latestStorageSelectionID: SaveFolderSelectionID?
    @State private var pendingStorageSelectionID: SaveFolderSelectionID?

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: pageIndex, total: OnboardingLayout.pageCount)
                .padding(.top, 22)        // 顶部呼吸（HIG ≥ 20）
                .padding(.bottom, 14)     // 进度点 ↔ 动画区

            // 翻页区。每个 page view 自己负责动画 + 文字 + 高度铺满。
            // 用条件渲染 + transition 做交叉淡入，而不是把所有页同时挂载
            // （避免像 TabView 那样让用户误以为可以左右拖）。
            // 翻页前后的 host endpoint 统一结束可能存在的录制 session。
            ZStack {
                page(pageIndex)
                    .id(pageIndex)
                    .transition(.opacity)
            }
            .animation(.smooth(duration: 0.35), value: pageIndex)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OnboardingFooter(
                pageIndex: $pageIndex,
                pendingStorageSelectionID: $pendingStorageSelectionID,
                onPageChange: endRecordingBeforePageChange,
                onFinish: close
            )
            .padding(.horizontal, 8)
            .padding(.top, 24)        // 副标题 ↔ 按钮（HIG: 副标题不该贴按钮）
            .padding(.bottom, 8)      // 左右与底边等距，贴近窗口底角
        }
        .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        // 不在 SwiftUI 这边自画窗口背景——onboarding 窗口由 OnboardingPresenter
        // 用 NSWindow 承载,默认 .windowBackgroundColor 已经给出 macOS 标准窗口
        // 背景。containerBackground(for: .window) 在 NSHostingController 路径下
        // 是 no-op,留着会让人误以为有效。
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0:
            OnboardingPagePermission(
                permissionManager: permissionManager,
                openScreenRecordingSettings: openScreenRecordingSettings,
                requestedOnce: $permissionRequestedOnce
            )
        case 1: OnboardingPageF5(shortcutFormatter: shortcutFormatter)
        case 2: OnboardingPageF7(shortcutFormatter: shortcutFormatter)
        case 3: OnboardingPageF6(shortcutFormatter: shortcutFormatter)
        case 4: OnboardingPageFrame(imageProcessor: imageProcessor)
        default:
            OnboardingPageStorage(
                latestSelectionID: $latestStorageSelectionID,
                pendingSelectionID: $pendingStorageSelectionID
            )
        }
    }

    private func close() {
        clearStorageSelectionIntent()
        onClose()
    }

    private func endRecordingBeforePageChange() {
        if pageIndex == OnboardingLayout.pageCount - 1 {
            clearStorageSelectionIntent()
        }
        shortcutService.endRecording(forHost: .onboarding, reason: .pageChanged)
    }

    private func clearStorageSelectionIntent() {
        latestStorageSelectionID = nil
        pendingStorageSelectionID = nil
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

/// Onboarding 底部按钮行。视觉在 macOS 26+ 用液态玻璃 `.glass` / `.glassProminent`
/// 按钮样式；部署下限是 15.6，因此通过下方 `glassButtonStyle(prominent:)` 的
/// `#available(macOS 26.0, *)` 分支，在更早系统回退到标准 `.bordered` / `.borderedProminent`。
///
/// "跳过"按钮仅在带有"跳过=显式拒绝"语义的页面显示（如画框页：
/// 跳过 = 不启用画框）。点击下一步 = 默认接受当前页的引导动作，
/// 点击跳过 = 显式撤回该动作。两个按钮都会推进到下一页。
///
/// 主操作按钮的可用性由当前页判定（如存储页要求用户做出明确选择）——
/// 这把"不做选择就 finish 导致 silent fail"的路径彻底封死。
struct OnboardingFooter: View {
    @Binding var pageIndex: Int
    @Binding var pendingStorageSelectionID: SaveFolderSelectionID?
    let onPageChange: () -> Void
    let onFinish: () -> Void

    @EnvironmentObject var capture: CaptureSettings
    @EnvironmentObject var saveFolderAccess: SaveFolderAccess

    private var skipBehavior: SkipBehavior? {
        switch pageIndex {
        case 4: return .frame
        default: return nil
        }
    }

    private enum SkipBehavior {
        case frame
    }

    /// 主操作按钮是否可用。存储页（pageIndex == 5）要求用户做出明确
    /// 选择（仅剪贴板 / 保存到有效文件夹之一）才允许 finish；其他页
    /// 始终可用（页面本身有默认值）。
    private var primaryEnabled: Bool {
        switch pageIndex {
        case 5:
            guard pendingStorageSelectionID == nil else { return false }
            if capture.saveToFile {
                if case .ready = saveFolderAccess.state { return true }
                return false
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
                changePage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .glassButtonStyle(prominent: false)
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
                    changePage(by: 1)
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
            .glassButtonStyle(prominent: true)
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
        changePage(by: 1)
    }

    private func changePage(by offset: Int) {
        onPageChange()
        withAnimation(.smooth(duration: 0.35)) { pageIndex += offset }
    }
}

// MARK: - Liquid Glass availability

private extension View {
    /// Applies the macOS 26 Liquid Glass button style, falling back to the
    /// standard bordered style on the 15.6 deployment floor. `#available` is
    /// the standard OS gate; glass is no longer assumed unconditionally present.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}
