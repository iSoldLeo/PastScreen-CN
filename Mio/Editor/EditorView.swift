//
//  EditorView.swift
//  Mio
//
//  CH-E3 编辑器 root view。
//
//  渲染分层（spec §5）：
//  - L1: 原图 — 静态 CGImage GPU texture
//  - L2: Canvas（透明）— 所有 commands + drafting，每帧重画
//  - L3: 文字矢量层（CH-E5 起接入；当前阶段空 ForEach）
//

import SwiftUI
import AppKit

struct EditorView: View {
    @State private var state: EditorState

    let onCancel: () -> Void
    let onFinish: (CGImage) -> Void

    init(
        image: CaptureImage,
        onCancel: @escaping () -> Void,
        onFinish: @escaping (CGImage) -> Void
    ) {
        self._state = State(initialValue: EditorState(image: image))
        self.onCancel = onCancel
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(state: state)
            canvasArea
                // 禁掉画布区的隐式动画（commands 增减、drafting 更新时不做溶解过渡），
                // 但保留工具栏区域的动画能力（工具切换 / 颜色组 slide）。
                .transaction { $0.animation = nil }
            footerBar
        }
        // SwiftUI fitting size 兜底 760×760：让 TextField 进/退编辑时的内部
        // fitting 抖动不传播到 NSHostingController.sizingOptions = [.minSize]
        // → 不触发窗口 contentMinSize 重算 → 图片不抖。配合 EditorWindowController
        // 的 sizingOptions 桥接，单一来源（SwiftUI fitting → window.contentMinSize）。
        .frame(minWidth: 760, minHeight: 760)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var canvasArea: some View {
        GeometryReader { proxy in
            let imageRect = imageDisplayRect(in: proxy.size)
            let imgSize = state.original.size
            let scaleFactor: CGFloat = imgSize.width > 0 ? imageRect.width / imgSize.width : 1

            ZStack {
                // L1: 原图静态背景
                Image(decorative: state.original.cgImage, scale: state.original.scale)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                // L2: 命令 + drafting 的统一 Canvas（透明，矢量重画）
                annotationCanvas(in: proxy.size)

                // L3: 文字层（矢量视图，每条标注一个独立 view 处理交互）
                ForEach(state.textAnnotations) { annotation in
                    TextAnnotationView(
                        state: state,
                        annotationID: annotation.id,
                        scaleFactor: scaleFactor,
                        imageRectOrigin: imageRect.origin
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(toolGesture(canvasSize: proxy.size))
            // 父级光标策略：
            // - 进入 canvas → set 当前工具光标
            // - 离开 canvas → set 回默认 arrow（让工具栏 / footer / 系统区域恢复正常）
            // - 工具/粗细变化时如果鼠标在画布内，由 onChange 触发重 set
            // 用 NSCursor.set() 而非 push/pop，避免栈失衡（push/pop 在工具切换
            // 跨 hover 边界时极易失衡 → 光标永远没法恢复）
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    EditorCursor.cursor(
                        for: state.tool,
                        thickness: state.thicknessIndex,
                        scaleFactor: scaleFactor
                    ).set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            // 工具/粗细变化时，若鼠标仍在画布内 onContinuousHover 不会再次触发，
            // 这里通过 onChange 主动重 set。如果鼠标不在画布，set 也无害——
            // SwiftUI / AppKit 下次 hover 任何 cursor rect 时会自动覆盖。
            .onChange(of: state.tool) { _, _ in
                EditorCursor.cursor(
                    for: state.tool,
                    thickness: state.thicknessIndex,
                    scaleFactor: scaleFactor
                ).set()
            }
            .onChange(of: state.thicknessIndex) { _, _ in
                guard state.tool == .mosaic else { return }
                EditorCursor.cursor(
                    for: state.tool,
                    thickness: state.thicknessIndex,
                    scaleFactor: scaleFactor
                ).set()
            }
            // 父级 clipped：文字超出 imageRect 时被裁掉（按用户预期）
            .clipped()
        }
        .padding(16)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    /// 注释层 Canvas — 命令时间序 + drafting。
    /// 命令存的是「源图 point 空间」坐标（与 FinalRenderer 一致）。Canvas 通过
    /// translate + scale 把源图坐标系映射到 imageRect 显示区域。
    private func annotationCanvas(in canvasSize: CGSize) -> some View {
        let imageRect = imageDisplayRect(in: canvasSize)
        let imgSize = state.original.size
        let scaleFactor: CGFloat = imgSize.width > 0
            ? imageRect.width / imgSize.width
            : 1

        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
            // 把绘图坐标系映射到 imageRect 显示区域：
            // 1. 原点平移到 imageRect 左上
            // 2. 缩放：源图 1pt = imageRect 中的 scaleFactor pt
            ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
            ctx.scaleBy(x: scaleFactor, y: scaleFactor)

            for cmd in state.commands {
                CommandRenderer.draw(
                    cmd,
                    in: &ctx,
                    fullPixelated: state.fullPixelated,
                    canvasSize: imgSize
                )
            }
            if let drafting = state.drafting {
                CommandRenderer.draw(
                    drafting,
                    in: &ctx,
                    fullPixelated: state.fullPixelated,
                    canvasSize: imgSize
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("common.cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("common.done") {
                if let final = FinalRenderer.render(state: state) {
                    onFinish(final)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Gesture

    /// 当前选中工具的拖动手势：mouseDown → drafting，mouseUp → commit + 清 drafting。
    /// .text 工具的交互单独处理（不走 drafting 模式）：mouseUp 时若未拖动且
    /// 落点不在已有文字框内 → 创建新文字 + 进编辑。
    private func toolGesture(canvasSize: CGSize) -> some Gesture {
        let imageRect = imageDisplayRect(in: canvasSize)
        return DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard state.tool != .text else { return }  // text 工具不走 drafting
                let start = imagePoint(value.startLocation, in: imageRect)
                let current = imagePoint(value.location, in: imageRect)
                state.drafting = makeDraft(
                    from: start,
                    to: current,
                    appendingTo: state.drafting
                )
            }
            .onEnded { value in
                let start = imagePoint(value.startLocation, in: imageRect)
                let end = imagePoint(value.location, in: imageRect)
                if state.tool == .text {
                    handleTextToolClick(at: end)
                    return
                }
                if let cmd = makeCommand(from: start, to: end, draft: state.drafting) {
                    state.commit(cmd)
                }
                state.drafting = nil
            }
    }

    /// .text 工具 mouseUp 处理：若已经在编辑某条文字 → 视为「点外面」结束编辑；
    /// 否则在落点创建新文字 + 进编辑（落点已被 TextAnnotationView 截获时此回调
    /// 不会被父级触发，所以「不在已有文字框内」自动满足）。
    private func handleTextToolClick(at point: CGPoint) {
        if state.editingTextID != nil {
            // TextField 失焦会自动触发 endEditing；这里兜底（用户从 .text 工具
            // 切到别的工具时 editing 会通过别的路径退出）
            state.endEditing()
            return
        }
        // 落点已经在源图 point 空间。创建新文字。
        state.startNewText(at: point)
    }

    /// 把 GeometryReader 坐标转换到「源图 point 空间」：
    /// 1. 减去 imageRect.origin 得到 imageRect 局部坐标（display 空间）
    /// 2. 除以 imageRect 与源图的比例（display → source point）
    /// 命令统一存源图 point 空间，与 FinalRenderer 合成时使用的坐标系一致。
    private func imagePoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        let imgSize = state.original.size
        guard imageRect.width > 0, imgSize.width > 0 else { return .zero }
        let invScale = imgSize.width / imageRect.width
        let local = CGPoint(x: point.x - imageRect.minX, y: point.y - imageRect.minY)
        // Clamp 到 [0, imgSize] 防止用户拖出 imageRect 外时存负值/超界
        let clamped = CGPoint(
            x: max(0, min(local.x * invScale, imgSize.width)),
            y: max(0, min(local.y * invScale, imgSize.height))
        )
        return clamped
    }

    /// 计算图像（scaledToFit）在 GeometryReader 内的实际显示矩形（point）。
    /// 图像源 size 是 state.original.size。
    private func imageDisplayRect(in containerSize: CGSize) -> CGRect {
        let imgSize = state.original.size
        guard imgSize.width > 0, imgSize.height > 0 else { return .zero }
        let containerAspect = containerSize.width / containerSize.height
        let imgAspect = imgSize.width / imgSize.height
        let displaySize: CGSize
        if imgAspect > containerAspect {
            // 图像更宽 → 按宽度铺满
            let w = containerSize.width
            let h = w / imgAspect
            displaySize = CGSize(width: w, height: h)
        } else {
            let h = containerSize.height
            let w = h * imgAspect
            displaySize = CGSize(width: w, height: h)
        }
        let originX = (containerSize.width - displaySize.width) / 2
        let originY = (containerSize.height - displaySize.height) / 2
        return CGRect(origin: CGPoint(x: originX, y: originY), size: displaySize)
    }

    // MARK: - Draft / Command construction

    /// 根据当前工具构造（或更新）drafting。
    private func makeDraft(
        from start: CGPoint,
        to current: CGPoint,
        appendingTo previous: DraftSnapshot?
    ) -> DraftSnapshot {
        let color = state.activeColor
        let thickness = state.thicknessIndex
        switch state.tool {
        case .rectangle:
            return .rectangle(rect: rectFromTwoPoints(start, current), color: color, thickness: thickness)
        case .ellipse:
            return .ellipse(rect: rectFromTwoPoints(start, current), color: color, thickness: thickness)
        case .arrow:
            return .arrow(from: start, to: current, color: color, thickness: thickness)
        case .pencil:
            // 增量 path：第一个点初始化，后续 addLine
            switch previous {
            case .pencil(let mutablePath, _, _):
                mutablePath.addLine(to: current)
                return .pencil(mutablePath: mutablePath, color: color, thickness: thickness)
            default:
                let mutablePath = CGMutablePath()
                mutablePath.move(to: start)
                if start != current {
                    mutablePath.addLine(to: current)
                }
                return .pencil(mutablePath: mutablePath, color: color, thickness: thickness)
            }
        case .mosaic:
            switch previous {
            case .mosaic(let mutablePath, _):
                mutablePath.addLine(to: current)
                return .mosaic(mutablePath: mutablePath, thickness: thickness)
            default:
                let mutablePath = CGMutablePath()
                mutablePath.move(to: start)
                if start != current {
                    mutablePath.addLine(to: current)
                }
                return .mosaic(mutablePath: mutablePath, thickness: thickness)
            }
        case .text:
            // 文字工具不走 drafting 模式：toolGesture 在 onEnded 时直接调
            // handleTextToolClick 创建文字。这里返回一个无害占位以保持 enum 完备。
            return .rectangle(rect: rectFromTwoPoints(start, current), color: color, thickness: thickness)
        }
    }

    /// onEnded 时根据 draft 构造正式 DrawCommand。
    /// 拖动距离过小（点击）时丢弃，避免误产生空命令。
    private func makeCommand(from start: CGPoint, to end: CGPoint, draft: DraftSnapshot?) -> DrawCommand? {
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        // minDrag 在「源图 point 空间」中判定 — 4pt 在 4K 屏 imageRect 缩到一半
        // 时仍约等于 2pt 显示距离，对单击误触够灵敏。
        let minDrag: CGFloat = 4

        switch state.tool {
        case .rectangle:
            let rect = rectFromTwoPoints(start, end)
            guard rect.width > minDrag || rect.height > minDrag else { return nil }
            return .rectangle(id: UUID(), rect: rect, color: state.activeColor, thickness: state.thicknessIndex)
        case .ellipse:
            let rect = rectFromTwoPoints(start, end)
            guard rect.width > minDrag || rect.height > minDrag else { return nil }
            return .ellipse(id: UUID(), rect: rect, color: state.activeColor, thickness: state.thicknessIndex)
        case .arrow:
            guard max(dx, dy) > minDrag else { return nil }
            return .arrow(id: UUID(), from: start, to: end, color: state.activeColor, thickness: state.thicknessIndex)
        case .pencil:
            // 单击丢弃（mutablePath.isEmpty 漏不住单击 — 已 move(to:)）
            guard max(dx, dy) > minDrag else { return nil }
            if case .pencil(let mutablePath, let color, let thickness) = draft,
               let frozen = mutablePath.copy() {
                return .pencil(id: UUID(), path: frozen, color: color, thickness: thickness)
            }
            return nil
        case .mosaic:
            guard max(dx, dy) > minDrag else { return nil }
            if case .mosaic(let mutablePath, let thickness) = draft,
               let frozen = mutablePath.copy() {
                return .mosaic(id: UUID(), path: frozen, thickness: thickness)
            }
            return nil
        case .text:
            return nil  // 已由 handleTextToolClick 处理
        }
    }

    private func rectFromTwoPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
