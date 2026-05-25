//
//  TextAnnotationView.swift
//  Mio
//
//  矢量文字标注视图（spec §6.6）。
//
//  锚点：origin = 文字框「左边中线」对应的源图 point
//        视图通过 .position + alignmentGuide 让左边缘对齐 origin.x、
//        垂直中线对齐 origin.y
//
//  状态机：
//  - 落笔态：仅显示文字（无边框）。
//      · 单击按住拖动 → 改 origin
//      · 双击 → 进编辑（系统 doubleClickInterval + 移动 ≤ 4pt 自动判定）
//      · 单次单击且未拖动 → 视为「未达双击」，无效
//  - 编辑态：带细边框 TextField，自适应宽度。
//      · 失焦（点外面 / Tab 走焦）→ endEditing
//      · ESC → endEditing
//      · 不响应拖动手势
//

import SwiftUI
import AppKit

struct TextAnnotationView: View {
    @Bindable var state: EditorState
    let annotationID: UUID
    /// 源图 point → 显示 point 的缩放系数（imageRect.width / image.size.width）
    let scaleFactor: CGFloat
    /// imageRect 在 GeometryReader 中的偏移
    let imageRectOrigin: CGPoint

    @FocusState private var isFocused: Bool
    @State private var dragOriginAtStart: CGPoint?
    @State private var isDragging: Bool = false

    var body: some View {
        if let annotation = state.textAnnotations.first(where: { $0.id == annotationID }) {
            let isEditing = state.editingTextID == annotation.id
            let displayFont = annotation.fontSize * scaleFactor
            let positionX = imageRectOrigin.x + annotation.origin.x * scaleFactor
            let positionY = imageRectOrigin.y + annotation.origin.y * scaleFactor

            // 锚点对齐策略：
            // - 父 ZStack(alignment: .topLeading) 默认让子视图左上角对齐 (0, 0)
            // - 把子视图的 .top 重定义为「垂直中线」→ 视图垂直中线对齐父 (0,0).y
            // - 然后 .offset 平移到 (positionX, positionY)
            // 结果：视图左边缘 = positionX，视图垂直中线 = positionY（左边中线对齐 origin）
            //
            // 不用 .position：.position 把视图中心硬性对齐到给定点，宽度变化时
            // 视觉上视图整体「漂移」（左右半各扩展 W/2）。.offset + alignment guide
            // 让左边缘成为不动点，宽度只向右增长，符合产品意图。
            ZStack(alignment: .topLeading) {
                content(annotation: annotation, isEditing: isEditing, displayFont: displayFont)
                    .fixedSize()
                    .alignmentGuide(VerticalAlignment.top) { dim in
                        dim[VerticalAlignment.center]
                    }
                    .offset(x: positionX, y: positionY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(
        annotation: TextAnnotation,
        isEditing: Bool,
        displayFont: CGFloat
    ) -> some View {
        let textColor = swiftUIColor(annotation.color)
        let horizPad = 6 * scaleFactor
        let vertPad = 4 * scaleFactor

        if isEditing {
            editingField(annotation: annotation, displayFont: displayFont, textColor: textColor)
                .padding(.horizontal, horizPad)
                .padding(.vertical, vertPad)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                )
        } else {
            displayLabel(annotation: annotation, displayFont: displayFont, textColor: textColor)
                .padding(.horizontal, horizPad)
                .padding(.vertical, vertPad)
                .contentShape(Rectangle())
                // hover 文字框时显示 openHand（提示「可拖动」）。
                // 拖动期间由 dragGesture 临时设 closedHand。
                // 离开时不主动 set arrow——父级 EditorView 的 onContinuousHover
                // 会在父级 hover phase = active 时把光标 set 回工具光标，
                // 文字框内（子）→ 文字框外（父）的过渡由 SwiftUI hit-test 自动协调。
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        if !isDragging {
                            NSCursor.openHand.set()
                        }
                    case .ended:
                        // 离开文字框：父级会立即收到 .active 重 set 工具光标
                        break
                    }
                }
                .gesture(dragGesture(annotation: annotation))
                .onTapGesture(count: 2) {
                    state.enterEditing(id: annotation.id)
                }
        }
    }

    // MARK: - Editing field

    private func editingField(
        annotation: TextAnnotation,
        displayFont: CGFloat,
        textColor: Color
    ) -> some View {
        let binding = Binding<String>(
            get: { state.textAnnotations.first(where: { $0.id == annotation.id })?.text ?? "" },
            set: { state.updateText(id: annotation.id, text: $0) }
        )

        return TextField("", text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: displayFont, weight: .medium))
            .foregroundStyle(textColor)
            .focused($isFocused)
            .task(id: state.editingTextID) {
                // SwiftUI focus 在 macOS 上有 view-lifecycle timing mismatch:
                // .task 触发时 NSTextField 可能还没完成 first responder attach。
                // 50ms 是「NSTextField attach 完毕」+「用户感知不到延迟」的甜点。
                if state.editingTextID == annotation.id {
                    try? await Task.sleep(for: .milliseconds(50))
                    if state.editingTextID == annotation.id {
                        isFocused = true
                    }
                }
            }
            .onChange(of: isFocused) { _, focused in
                // 失焦 = 用户点了外面，结束编辑
                if !focused {
                    state.endEditing()
                }
            }
            .onSubmit {
                state.endEditing()
            }
            .onExitCommand {
                state.endEditing()
            }
    }

    // MARK: - Display label

    private func displayLabel(
        annotation: TextAnnotation,
        displayFont: CGFloat,
        textColor: Color
    ) -> some View {
        Text(annotation.text)
            .font(.system(size: displayFont, weight: .medium))
            .foregroundStyle(textColor)
    }

    // MARK: - Drag

    /// 落笔态拖动：移动 ≥ 4pt 才算开始拖动（SwiftUI minimumDistance）。
    /// 第一次 onChanged 记下 origin 起点，后续按 startLocation→location 增量更新。
    private func dragGesture(annotation: TextAnnotation) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragOriginAtStart == nil {
                    dragOriginAtStart = annotation.origin
                    isDragging = true
                    NSCursor.closedHand.set()
                }
                guard let start = dragOriginAtStart else { return }
                let dx = (value.location.x - value.startLocation.x) / scaleFactor
                let dy = (value.location.y - value.startLocation.y) / scaleFactor
                state.moveText(id: annotation.id, to: CGPoint(x: start.x + dx, y: start.y + dy))
            }
            .onEnded { _ in
                dragOriginAtStart = nil
                isDragging = false
                NSCursor.openHand.set()
            }
    }

    // MARK: - Color

    private func swiftUIColor(_ ref: ColorRef) -> Color {
        switch ref {
        case .preset(let i):
            return editorPresetColors[max(0, min(i, editorPresetColors.count - 1))].color
        case .sampled(let r, let g, let b, let a):
            return Color(red: r, green: g, blue: b, opacity: a)
        }
    }
}
