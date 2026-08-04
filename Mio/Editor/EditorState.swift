//
//  EditorState.swift
//  Mio
//
//  编辑器状态 + 工具集 + 颜色集 + 命令栈 + DraftSnapshot。
//
//  全矢量方案（spec §4-§5）：
//  - 撤销栈只存命令描述（DrawCommand），不存 CGImage 副本
//  - 不维护 baseline cache，原图作为静态背景，所有命令每帧重画
//  - 撤销 / 重做 = O(1) 数组操作
//  - 马赛克粒度固定；fullPixelated 惰性生成（切到马赛克工具时预热），
//    不在开窗路径上做像素工作
//

import Foundation
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Tools

/// 编辑器工具集（PRODUCT v5 §3.4 锁定，6 项不可扩展）。
enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case rectangle, ellipse, arrow, pencil, mosaic, text
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse:   "circle"
        case .arrow:     "arrow.up.right"
        case .pencil:    "pencil.tip"
        case .mosaic:    "rectangle.checkered"
        case .text:      ""  // 见 EditorToolbar.ToolButton：text 单独渲染拉丁字母 "A"
        }
    }

    var label: String {
        switch self {
        case .rectangle: return String(localized: "editor.tool.rectangle", defaultValue: "矩形")
        case .ellipse:   return String(localized: "editor.tool.ellipse", defaultValue: "椭圆")
        case .arrow:     return String(localized: "editor.tool.arrow", defaultValue: "箭头")
        case .pencil:    return String(localized: "editor.tool.pencil", defaultValue: "画笔")
        case .mosaic:    return String(localized: "editor.tool.mosaic", defaultValue: "马赛克")
        case .text:      return String(localized: "editor.tool.text", defaultValue: "文字")
        }
    }
}

// MARK: - Color presets

/// 编辑器 7 色预设（PRODUCT v5 §3.4 锁定）。
let editorPresetColors: [(name: String, color: Color)] = [
    ("red",    Color(red: 0.92, green: 0.20, blue: 0.18)),
    ("orange", Color(red: 0.98, green: 0.65, blue: 0.16)),
    ("green",  Color(red: 0.20, green: 0.78, blue: 0.42)),
    ("blue",   Color(red: 0.10, green: 0.50, blue: 0.96)),
    ("white",  .white),
    ("gray",   Color(red: 0.55, green: 0.55, blue: 0.55)),
    ("black",  .black),
]

/// Sendable 颜色引用：要么是 7 色预设的 index，要么是「最近取色」的 RGBA 拷贝。
/// 不直接存 SwiftUI Color（非 Sendable）。
enum ColorRef: Equatable, Sendable {
    case preset(Int)
    case sampled(red: Double, green: Double, blue: Double, alpha: Double)
}

// MARK: - Thickness

/// 3 档粗细对应的实际线宽（point）。形态在 Toolbar 内根据工具切换。
enum Thickness {
    /// 矩形 / 椭圆 / 箭头：线条粗细
    static func strokeWidth(_ index: Int) -> CGFloat { [2, 4, 7][index] }
    /// 画笔:笔触粗细（首尾圆头）
    static func pencilWidth(_ index: Int) -> CGFloat { [3, 6, 11][index] }
    /// 马赛克：方头画笔粗细（不影响粒度）
    static func mosaicWidth(_ index: Int) -> CGFloat { [8, 16, 28][index] }
    /// 文字：三档字号（源图 point 空间）
    static func textFontSize(_ index: Int) -> CGFloat { [14, 18, 24][index] }
    /// 箭头尖部长度（与 lineWidth 弱关联）
    static func arrowheadLength(_ index: Int) -> CGFloat {
        max(strokeWidth(index) * 4.5, 12)
    }
}

// MARK: - DrawCommand

/// 已落地的绘制命令。CGPath 预构造（不存 [CGPoint]），多次 stroke 同一 path
/// GPU 缓存友好，避免每帧重新构造路径。
///
/// 不 Sendable（CGPath 非 Sendable），但命令栈在 @MainActor EditorState 内
/// 不跨 actor，无需声明 Sendable。
enum DrawCommand: Identifiable {
    case rectangle(id: UUID, rect: CGRect, color: ColorRef, thickness: Int)
    case ellipse(id: UUID, rect: CGRect, color: ColorRef, thickness: Int)
    case arrow(id: UUID, from: CGPoint, to: CGPoint, color: ColorRef, thickness: Int)
    case pencil(id: UUID, path: CGPath, color: ColorRef, thickness: Int)
    case mosaic(id: UUID, path: CGPath, thickness: Int)

    var id: UUID {
        switch self {
        case .rectangle(let id, _, _, _),
             .ellipse(let id, _, _, _),
             .arrow(let id, _, _, _, _),
             .pencil(let id, _, _, _),
             .mosaic(let id, _, _):
            return id
        }
    }
}

// MARK: - Drafting (实时拖动期临时形状)

/// 用户手指还按着时的临时形状。松开手指时变成 DrawCommand 入栈。
/// 与 DrawCommand 共用渲染路径，只是不进 commands 数组。
enum DraftSnapshot {
    case rectangle(rect: CGRect, color: ColorRef, thickness: Int)
    case ellipse(rect: CGRect, color: ColorRef, thickness: Int)
    case arrow(from: CGPoint, to: CGPoint, color: ColorRef, thickness: Int)
    /// 画笔 / 马赛克：实时累积的点序列。每个 onChanged 增量 addLine 到 mutablePath。
    case pencil(mutablePath: CGMutablePath, color: ColorRef, thickness: Int)
    case mosaic(mutablePath: CGMutablePath, thickness: Int)
}

// MARK: - EditorState

@Observable @MainActor
final class EditorState {
    let original: CaptureImage

    /// 整张图的 pixellate 版本，马赛克命令用 path 作为 clip mask 把对应区域画到
    /// 画布。**惰性生成**：绝大多数编辑会话不用马赛克，进编辑器时无条件预生成
    /// 等于白花 ~30ms（4K）。首次真正需要时才算，之后缓存复用。
    ///
    /// 为什么是「永远可得的计算属性」而不是「可选值 + 渲染时跳过」：
    /// 马赛克是**打码**工具（PRODUCT.md §8「马赛克粒度固定所以打码不会泄漏」）。
    /// 如果渲染层拿到 nil 就静默跳过，`FinalRenderer` 会输出一张**未打码**的图 ——
    /// 用户以为遮住了，实际没有。这里宁可付 30ms 也不给出"静默降级"的可能。
    /// 因此本属性没有失败路径：任何时候读都保证返回可用图像。
    ///
    /// 触发时机见 `tool` 的 `didSet`：切到马赛克工具时就预热，让第一笔拖动之前
    /// 完成计算，而不是卡在拖动中间。
    var fullPixelated: CGImage {
        if let pixellatedCache { return pixellatedCache }
        let generated = Self.makePixellated(original.cgImage)
        pixellatedCache = generated
        return generated
    }

    /// `@ObservationIgnored` 是必需的：本缓存会在 SwiftUI Canvas 求值过程中被写入
    /// （渲染马赛克命令时），若被 `@Observable` 追踪就会在视图更新期间触发状态变更。
    @ObservationIgnored private var pixellatedCache: CGImage?

    var commands: [DrawCommand] = []
    var redoQueue: [DrawCommand] = []
    var textAnnotations: [TextAnnotation] = []
    /// 当前正在编辑的文字 ID（编辑态时显示带边框 TextField）。nil = 无编辑中文字。
    var editingTextID: UUID?

    /// 拖动期临时形状（drafting）。@Observable 让 Canvas closure 在它变化时
    /// 重新执行；不在则只显示 commands 数组。
    var drafting: DraftSnapshot?

    // 跨工具共享的 UI 状态（切换工具时不重置）
    var tool: EditorTool = .rectangle {
        didSet {
            // 切到非文字工具时自动结束编辑（避免状态错乱）
            if oldValue == .text && tool != .text {
                endEditing()
            }
            // 预热马赛克底图：选中工具是一次离散点击，有天然的等待容忍度；
            // 等到第一笔拖动中间再算会卡在描边过程里。同步执行是刻意的 ——
            // 保证第一笔一定顺滑。若日后要连这 30ms 也消掉，可以改成
            // 异步预热 + 首笔前 await，但那要引入"底图还没好"的中间态。
            if tool == .mosaic {
                _ = fullPixelated
            }
        }
    }
    var colorIndex: Int = 0
    var sampledColor: ColorRef?
    var usingSampled: Bool = false
    var thicknessIndex: Int = 1

    var canUndo: Bool { !commands.isEmpty }
    var canRedo: Bool { !redoQueue.isEmpty }

    var activeColor: ColorRef {
        usingSampled ? (sampledColor ?? .preset(colorIndex)) : .preset(colorIndex)
    }

    /// 不在这里生成 `fullPixelated` —— 见该属性的注释。编辑器开窗路径上零像素工作。
    init(image: CaptureImage) {
        self.original = image
    }

    func commit(_ cmd: DrawCommand) {
        commands.append(cmd)
        redoQueue.removeAll()  // 编辑后 redo 失效（标准撤销栈语义）
    }

    func undo() {
        guard let last = commands.popLast() else { return }
        redoQueue.append(last)
    }

    func redo() {
        guard let cmd = redoQueue.popLast() else { return }
        commands.append(cmd)
    }

    // MARK: - Text annotation operations

    /// 在画布点 P 处创建一条新文字，并立即进入编辑态。
    /// 若已有编辑中的文字，先 endEditing（自动清理空文字）。
    @discardableResult
    func startNewText(at point: CGPoint) -> UUID {
        endEditing()
        let id = UUID()
        textAnnotations.append(TextAnnotation(
            id: id,
            origin: point,
            text: "",
            color: activeColor,
            fontSize: Thickness.textFontSize(thicknessIndex)
        ))
        editingTextID = id
        return id
    }

    func updateText(id: UUID, text: String) {
        guard let idx = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[idx].text = text
    }

    func moveText(id: UUID, to point: CGPoint) {
        guard let idx = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[idx].origin = point
    }

    func enterEditing(id: UUID) {
        // 切换编辑态前先 end 之前的（若有），保证同时只有一条编辑中
        endEditing()
        editingTextID = id
    }

    /// 结束当前编辑：若文字内容为空则丢弃整条标注（用户单击但未输入）。
    func endEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if let idx = textAnnotations.firstIndex(where: { $0.id == id }),
           textAnnotations[idx].text.isEmpty {
            textAnnotations.remove(at: idx)
        }
    }

    // MARK: - Pixellate baseline

    private static let pixellateScale: Double = 16

    private static func makePixellated(_ source: CGImage) -> CGImage {
        let ciImage = CIImage(cgImage: source)
        let filter = CIFilter.pixellate()
        filter.inputImage = ciImage
        filter.scale = Float(pixellateScale)
        filter.center = CGPoint(x: source.width / 2, y: source.height / 2)
        let context = CIContext(options: nil)
        guard let output = filter.outputImage,
              let cg = context.createCGImage(output, from: ciImage.extent) else {
            return source  // 回退：fallback 用原图（视觉退化但不崩）
        }
        return cg
    }
}

// MARK: - TextAnnotation (CH-E5)

/// 文字标注（矢量对象，可拖可改）。坐标系是源图 point 空间，与 DrawCommand 一致。
///
/// origin = 文字框「左边中线」对应的点（spec §6.6）：
/// - 用户单击点 P 处创建文字时，P 直接成为 origin
/// - 编辑态时显示带边框输入框，左边中线对齐 origin
/// - 非编辑态时仅显示文字本身，无边框；单击可拖动改 origin、双击重新进入编辑
struct TextAnnotation: Identifiable {
    let id: UUID
    var origin: CGPoint
    var text: String
    var color: ColorRef
    /// 源图 point 空间字号（合成时用）。display 时需乘 scaleFactor。
    var fontSize: CGFloat
}
