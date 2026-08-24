//
//  EditorToolbar.swift
//  Mio
//
//  编辑器单行工具栏。视觉布局与 EditorToolbarMockup 一致：
//
//    粗细 | 7 色 | 取色器 + 取色结果圆 |  spacer  | 6 工具 | 撤销 / 恢复
//
//  CH-E3 接入：撤销 / 恢复按钮调 state.undo() / state.redo()；
//             ColorRef 替代旧的 SwiftUI Color sampledColor。
//

import SwiftUI
import AppKit

struct EditorToolbar: View {
    @Bindable var state: EditorState
    let onRequestColorSampling: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 左：粗细（形态随当前工具切换）
            HStack(spacing: 4) {
                ForEach(0..<3) { level in
                    ThicknessSelector(
                        tool: state.tool,
                        level: level,
                        isSelected: state.thicknessIndex == level
                    ) { state.thicknessIndex = level }
                }
            }

            // 颜色 + 取色组：马赛克时整组滑左隐藏。
            // 用 .mask 限定可见区域到分隔线右侧—粗细按钮所在区域不会被颜色组
            // 滑动时穿过。.transition(.move(edge: .leading)) 让进出从左缘开始。
            ColorGroup(state: state, onRequestColorSampling: onRequestColorSampling)

            Spacer(minLength: 16)

            // 右：6 工具
            HStack(spacing: 6) {
                ForEach(EditorTool.allCases) { tool in
                    ToolButton(
                        tool: tool,
                        isSelected: state.tool == tool
                    ) { state.tool = tool }
                }
            }

            Divider().frame(height: 22)

            // 撤销 / 恢复
            HStack(spacing: 4) {
                Button {
                    state.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canUndo)
                .help("common.undo")
                .keyboardShortcut("z", modifiers: [.command])

                Button {
                    state.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canRedo)
                .help("common.redo")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        // 工具切换时给颜色组做 slide 动画
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.tool == .mosaic)
    }
}

// MARK: - 颜色 + 取色组

/// 颜色 + 取色器整组。马赛克工具时整体向左滑出隐藏；其他工具时滑入。
/// 用独立容器 + .clipped 限定动画范围在自己边界内，避免向左滑动时
/// 越过分隔线侵入粗细按钮区域。
private struct ColorGroup: View {
    @Bindable var state: EditorState
    let onRequestColorSampling: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if state.tool != .mosaic {
                Divider().frame(height: 22)

                HStack(spacing: 2) {
                    ForEach(Array(editorPresetColors.enumerated()), id: \.offset) { index, item in
                        ColorSwatch(
                            color: item.color,
                            isSelected: !state.usingSampled && state.colorIndex == index
                        ) {
                            state.colorIndex = index
                            state.usingSampled = false
                        }
                    }
                }

                Divider().frame(height: 22)

                HStack(spacing: 4) {
                    EyedropperButton {
                        onRequestColorSampling()
                    }
                    SampledColorDot(
                        color: sampledSwiftUIColor(state.sampledColor),
                        isSelected: state.usingSampled
                    ) {
                        if state.sampledColor != nil {
                            state.usingSampled = true
                        }
                    }
                }
            }
        }
        // clipped 把动画约束在容器自己的水平范围内，向左滑出时不会穿过左侧
        // 的粗细按钮区域。马赛克时容器空 → HStack 自然宽度为 0，不占位。
        .clipped()
    }

    private func sampledSwiftUIColor(_ ref: ColorRef?) -> Color? {
        switch ref {
        case .sampled(let r, let g, let b, let a):
            return Color(red: r, green: g, blue: b, opacity: a)
        case .preset, nil:
            return nil
        }
    }
}

// MARK: - 子组件

private struct ToolButton: View {
    let tool: EditorTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if tool == .text {
                    Text("A")
                        .font(.system(size: 17, weight: .semibold))
                } else {
                    Image(systemName: tool.icon)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.borderless)
        .help(tool.label)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

private struct ColorSwatch: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .padding(3)
                .background(
                    Circle()
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
}

/// 粗细选择器：形态随当前工具切换（spec §15）。
///   矩形 / 椭圆 / 箭头 / 画笔 → 圆点（直径递增）
///   马赛克                  → 方块（边长递增，影响方头画笔大小）
///   文字                    → 数字 1 / 2 / 3（对应 14 / 18 / 24 字号）
private struct ThicknessSelector: View {
    let tool: EditorTool
    let level: Int       // 0=细 1=中 2=粗
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())  // 整个 26×26 区域都可点，不限于内部图标
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: tool)
    }

    @ViewBuilder
    private var content: some View {
        switch tool {
        case .text:
            Text("\(level + 1)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        case .mosaic:
            let side: CGFloat = [5, 8, 12][level]
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.primary)
                .frame(width: side, height: side)
        default:
            let diameter: CGFloat = [4, 7, 11][level]
            Circle()
                .fill(.primary)
                .frame(width: diameter, height: diameter)
        }
    }
}

private struct EyedropperButton: View {
    let onPick: () -> Void
    var body: some View {
        Button(action: onPick) {
            Image(systemName: "eyedropper")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help("editor.eyedropper.help")
    }
}

private struct SampledColorDot: View {
    let color: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                } else {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                        )
                        .frame(width: 18, height: 18)
                }
            }
            .padding(3)
            .background(
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(color == nil)
        .help(color == nil ? LocalizedStringKey("editor.sampled_color.empty") : LocalizedStringKey("editor.sampled_color.use"))
    }
}
