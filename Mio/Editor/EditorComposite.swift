//
//  EditorComposite.swift
//  Mio
//
//  Module-09 async final compositor value boundary (M09-03 / Review1 F02).
//
//  MainActor 一次性从 `EditorState` 生成一份**不可变、Sendable** 的
//  `EditorCompositeSnapshot`，交给 off-MainActor 的 `EditorCompositeRenderer`
//  actor 做全分辨率合成。快照不含任何非 Sendable 对象：矩形/椭圆/箭头用标量
//  几何，pencil/mosaic 的 `CGPath` 展平成点序列（`CGPath` 非 Sendable），文字
//  只带 String/位置/颜色/字号等值，source/pixelated source 复用 `CaptureImage`。
//

import CoreGraphics

// MARK: - Sendable command / text values

/// 一条已完成标注的值描述，可安全交给 off-MainActor compositor。
/// pencil/mosaic 因 `CGPath` 非 Sendable 被展平为点折线（它们本就是单条
/// move→line 连续笔画）。
nonisolated enum CompositeCommand: Sendable, Equatable {
    case rectangle(rect: CGRect, color: ColorRef, thickness: Int)
    case ellipse(rect: CGRect, color: ColorRef, thickness: Int)
    case arrow(from: CGPoint, to: CGPoint, color: ColorRef, thickness: Int)
    case pencil(points: [CGPoint], color: ColorRef, thickness: Int)
    case mosaic(points: [CGPoint], thickness: Int)
}

nonisolated struct CompositeText: Sendable, Equatable {
    let origin: CGPoint
    let text: String
    let color: ColorRef
    let fontSize: CGFloat
}

/// 编辑器文档在某一时刻的不可变、Sendable 快照。MainActor 生成，actor 合成。
nonisolated struct EditorCompositeSnapshot: Sendable {
    let original: CaptureImage
    let pixelatedSource: CaptureImage?
    let commands: [CompositeCommand]
    let texts: [CompositeText]
}

nonisolated enum EditorCompositeError: Error, Sendable, Equatable {
    case invalidDimensions
    case contextCreationFailed
    case imageCreationFailed
    /// 快照含 `.mosaic` 命令却无 pixelated source——绝不能静默略过打码返回原像素。
    case missingPixelatedSource
    /// 马赛克命令的点序列为空/非法。
    case invalidMosaicPath
}

// MARK: - MainActor snapshot builder

extension EditorCompositeSnapshot {
    /// 在 MainActor 从当前编辑状态一次性冻结快照；空文字被跳过（不参与合成）。
    @MainActor
    static func capture(from state: EditorState) -> EditorCompositeSnapshot {
        let pixelated: CaptureImage?
        if case .ready(let image) = state.mosaicPhase {
            pixelated = image
        } else {
            pixelated = nil
        }

        var commands: [CompositeCommand] = []
        commands.reserveCapacity(state.commands.count)
        for command in state.commands {
            commands.append(CompositeCommand(command))
        }

        var texts: [CompositeText] = []
        for annotation in state.textAnnotations where !annotation.text.isEmpty {
            texts.append(CompositeText(
                origin: annotation.origin,
                text: annotation.text,
                color: annotation.color,
                fontSize: annotation.fontSize
            ))
        }

        return EditorCompositeSnapshot(
            original: state.original,
            pixelatedSource: pixelated,
            commands: commands,
            texts: texts
        )
    }
}

extension CompositeCommand {
    /// 从 MainActor `DrawCommand` 冻结为 Sendable 值；pencil/mosaic 的 path 展平。
    @MainActor
    init(_ command: DrawCommand) {
        switch command {
        case .rectangle(_, let rect, let color, let thickness):
            self = .rectangle(rect: rect, color: color, thickness: thickness)
        case .ellipse(_, let rect, let color, let thickness):
            self = .ellipse(rect: rect, color: color, thickness: thickness)
        case .arrow(_, let from, let to, let color, let thickness):
            self = .arrow(from: from, to: to, color: color, thickness: thickness)
        case .pencil(_, let path, let color, let thickness):
            self = .pencil(points: path.polylinePoints(), color: color, thickness: thickness)
        case .mosaic(_, let path, let thickness):
            self = .mosaic(points: path.polylinePoints(), thickness: thickness)
        }
    }
}

// MARK: - CGPath flattening

extension CGPath {
    /// 展平仅由 move/line 组成的笔画（pencil/mosaic）为点序列。curve/quad 元素
    /// 不会出现在这两类笔画里，安全忽略。
    func polylinePoints() -> [CGPoint] {
        var points: [CGPoint] = []
        applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.pointee.points[0])
            default:
                break
            }
        }
        return points
    }
}
