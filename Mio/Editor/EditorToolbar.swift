//
//  EditorToolbar.swift
//  Mio
//
//  编辑器单行工具栏（A1 仿 QQ 布局）。视觉与 EditorToolbarMockup 完全一致，
//  只是把 Mock 模型换成产品的 EditorState / EditorTool。
//
//  布局（左 → 右）：
//    粗细 | 7 色 | 取色器 + 取色结果圆 |  spacer  | 6 工具 | 撤销 / 恢复
//
//  最窄约 743pt（spacer 收成 0），自然下限 760pt。
//  详见 docs/editor.md §15 粗细选择器形态切换 + §14 工具按钮的视觉特例。
//

import SwiftUI
import AppKit

struct EditorToolbar: View {
    @Bindable var state: EditorState

    var body: some View {
        HStack(spacing: 12) {
            // 左：粗细（形态随当前工具切换）
            HStack(spacing: 4) {
                ForEach(0..<3) { level in
                    ThicknessSelector(
                        tool: state.tool,
                        level: level,
                        isSelected: state.thickness == level
                    ) { state.thickness = level }
                }
            }

            Divider().frame(height: 22)

            // 7 色预设
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

            // 取色器 + 取色结果
            HStack(spacing: 4) {
                EyedropperButton {
                    // CH-E6 起接入 NSColorSampler 真 API。当前阶段
                    // 临时用随机色模拟（mockup 行为），让 UI 流转可见。
                    state.sampledColor = Color(
                        red: .random(in: 0...1),
                        green: .random(in: 0...1),
                        blue: .random(in: 0...1)
                    )
                    state.usingSampled = true
                }
                SampledColorDot(
                    color: state.sampledColor,
                    isSelected: state.usingSampled
                ) {
                    if state.sampledColor != nil {
                        state.usingSampled = true
                    }
                }
            }

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
                    // CH-E3 起接入命令栈 undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canUndo)
                .help("撤销")

                Button {
                    // CH-E3 起接入命令栈 redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canRedo)
                .help("恢复")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
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
                    // 直接渲染拉丁字母 A（无衬线，跟 SF Symbol 风格统一），
                    // 避免 SF Symbol "character" 在中文 locale 显示成"字"
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
        .help("屏幕取色")
    }
}

/// 显示最近一次屏幕取色结果。未取色时灰色虚边占位；取色后填入颜色。
/// 单击此圆 = 把当前激活色切换为最近取色（与预设 7 色互斥）。
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
        .help(color == nil ? "尚未取色" : "使用刚才取到的颜色")
    }
}
