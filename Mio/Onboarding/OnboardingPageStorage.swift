//
//  OnboardingPageStorage.swift
//  Mio
//
//  Onboarding 第 5 页：截图存到哪。
//
//  叙事策略（与 P4 不同）：这一页给用户**明确选择**,没有隐式默认。
//  两张并列卡:仅剪贴板 / 也保存到文件夹。原因:
//
//    1. 合规 gate(Apple 2.4.5(i)):新用户 saveFolderPath = ""
//       默认 saveToFile = true → 不主动选会"想保存但写不了文件"
//       silent fail。
//    2. 这是工具型应用的核心交互预设——比"启用画框"重得多。HIG
//       反对在重交互上用"默认接受 + 跳过"模式,该模式适合可逆的
//       装饰性选择(如 P4 画框),不适合关乎产品基本行为的选择。
//    3. 显式选择让用户对自己的工作流有掌控感,符合"工具感"产品调性。
//
//  按钮契约:
//    · 「开始使用」按钮在用户做出**有效选择**前 disabled
//        - 仅剪贴板 = 有效
//        - 保存到文件 + 路径有效 = 有效
//        - 其他都不允许 finish
//    · 没有「跳过」按钮——本页不存在"跳过"语义,必须做出选择
//
//  视觉:两张选择卡平铺占据 stage 主体。已选卡片用 accent 色描边
//  + 角标 checkmark.circle.fill,未选卡片走 .glass 中性玻璃感。
//  卡片之上无图标罗列 - 直接图标 + 标题 + 一行描述,让用户两秒读完。
//

import SwiftUI
import AppKit

// MARK: - Page

struct OnboardingPageStorage: View {
    @EnvironmentObject var capture: CaptureSettings

    var body: some View {
        OnboardingPageShell(
            title: "onboarding.storage.title",
            subtitle: "onboarding.storage.subtitle"
        ) {
            StorageChoicesStage()
        } action: {
            // action 槽:已选"保存到文件"时显示路径行;否则什么都不画
            // 让 stage 居中。这样 stage 的卡片永远是视觉重心。
            if capture.saveToFile && capture.hasValidSaveFolder {
                CurrentFolderRow()
            }
        }
    }
}

// MARK: - Stage

private struct StorageChoicesStage: View {
    @EnvironmentObject var capture: CaptureSettings

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 16) {
                // 卡片 1:仅剪贴板
                StorageChoiceCard(
                    iconName: "doc.on.clipboard",
                    title: "onboarding.storage.clipboard.title",
                    subtitle: "onboarding.storage.clipboard.subtitle",
                    isSelected: !capture.saveToFile,
                    accent: .blue
                ) {
                    selectClipboardOnly()
                }

                // 卡片 2:保存到文件
                StorageChoiceCard(
                    iconName: "folder.fill",
                    title: "onboarding.storage.file.title",
                    subtitle: "onboarding.storage.file.subtitle",
                    isSelected: capture.saveToFile && capture.hasValidSaveFolder,
                    accent: .orange
                ) {
                    selectSaveToFolder()
                }
            }
            .padding(20)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func selectClipboardOnly() {
        capture.saveToFile = false
    }

    /// 弹 NSOpenPanel 让用户选文件夹。选了就同时打开 saveToFile + 写路径;
    /// cancel 不切换状态(不强行让卡片 2 高亮然后留在无路径状态)。
    private func selectSaveToFolder() {
        NSApp.activate(ignoringOtherApps: true)
        if let path = capture.selectFolder() {
            capture.saveFolderPath = path
            capture.saveToFile = true
        }
    }
}

// MARK: - Choice card

private struct StorageChoiceCard: View {
    let iconName: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    // 图标:大色块强化"两条路"的对比识别度
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent.opacity(isSelected ? 0.18 : 0.10))
                            .frame(width: 56, height: 56)
                        Image(systemName: iconName)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    Spacer()

                    // 选中角标
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(accent)
                        .opacity(isSelected ? 1 : 0)
                        .scaleEffect(isSelected ? 1 : 0.6)
                        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isSelected)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent.opacity(0.85) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(
                color: isSelected ? accent.opacity(0.18) : .black.opacity(0.04),
                radius: isSelected ? 14 : 6,
                y: isSelected ? 6 : 2
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.22), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Current folder row (action slot)

/// 已选"保存到文件"且路径有效时,在 action 槽里显示当前文件夹 + 更改按钮。
/// 与 P1–P3 的快捷键按钮、P4 的签名输入框处于同一视觉位置——保持
/// "副标题下方一行操作区"的位置感。
private struct CurrentFolderRow: View {
    @EnvironmentObject var capture: CaptureSettings

    private var folderName: String {
        let url = URL(fileURLWithPath: capture.saveFolderPath)
        let name = url.lastPathComponent
        return name.isEmpty ? capture.saveFolderPath : name
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)

            Text(folderName)
                .font(.system(.body, design: .default).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Button("onboarding.storage.change") {
                changeFolder()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .frame(maxWidth: 360)
    }

    private func changeFolder() {
        NSApp.activate(ignoringOtherApps: true)
        if let path = capture.selectFolder() {
            capture.saveFolderPath = path
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingPageStorage()
        .environmentObject(AppSettings.shared.capture)
        .frame(width: 720, height: 480)
}
