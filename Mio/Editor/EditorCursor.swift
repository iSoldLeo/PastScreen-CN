//
//  EditorCursor.swift
//  Mio
//
//  画布区光标策略（spec / 用户反馈对齐）。
//
//  | 工具 / 状态                       | 光标         |
//  | --------------------------------- | ------------ |
//  | 矩形 / 椭圆 / 箭头 / 画笔        | crosshair    |
//  | 马赛克                           | 灰色方块（跟随 thickness 大小）|
//  | 文字 + 画布空白处                | crosshair（系统的 + 形态）|
//  | 文字 + 文字框上（落笔态）        | openHand     |
//  | 拖动文字中                        | closedHand   |
//  | TextField 编辑态                  | iBeam（系统给）|
//
//  实现：父级 .onContinuousHover 设光标；子视图（TextAnnotationView）的
//  .onContinuousHover 局部覆盖，离开子视图后父级 hover 重新生效。
//

import AppKit

@MainActor
enum EditorCursor {
    /// scaleFactor = imageRect.width / image.size.width，把源图 point 笔触宽度
    /// 映射到画布显示尺寸。光标只跟显示一致，不跟源图一致——用户期望「光标
    /// 方块 = 实际画出来的方块」。
    static func cursor(for tool: EditorTool, thickness: Int, scaleFactor: CGFloat) -> NSCursor {
        switch tool {
        case .rectangle, .ellipse, .arrow, .pencil:
            return .crosshair
        case .mosaic:
            return mosaicCursor(thickness: thickness, scaleFactor: scaleFactor)
        case .text:
            return .crosshair
        }
    }

    /// 按当前马赛克方头画笔粗细生成方块光标。深灰色半透明，与「真实画出来」
    /// 的笔触视觉一致。thickness / scaleFactor 变化时调用方需重新拿光标。
    static func mosaicCursor(thickness: Int, scaleFactor: CGFloat) -> NSCursor {
        let side = max(2, Thickness.mosaicWidth(thickness) * scaleFactor)
        // 加 1pt 是给 1pt 描边让出空间，避免方块边缘超出 NSImage 范围
        let imageSize = CGSize(width: side + 1, height: side + 1)
        let image = NSImage(size: imageSize, flipped: false) { rect in
            NSColor.darkGray.withAlphaComponent(0.85).setFill()
            let inner = CGRect(origin: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: side, height: side))
            inner.fill()
            // 1pt 白色描边让方块在深色画布上仍可辨识
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(rect: inner)
            path.lineWidth = 1
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
    }
}
