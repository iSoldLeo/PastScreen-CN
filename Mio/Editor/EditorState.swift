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
//  - 马赛克粒度固定；06 actor 异步生成 pixelated source，ready 前不创建命令
//

import Foundation
import SwiftUI

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
/// 不直接存 SwiftUI Color（非 Sendable）。nonisolated：纯值，MainActor UI 与
/// off-MainActor compositor（`EditorCompositeSnapshot`/`EditorCompositeRenderer`）共用。
nonisolated enum ColorRef: Equatable, Sendable {
    case preset(Int)
    case sampled(red: Double, green: Double, blue: Double, alpha: Double)
}

// MARK: - Thickness

/// 3 档粗细对应的实际线宽（point）。形态在 Toolbar 内根据工具切换。
/// 3 档粗细对应的实际线宽（point）。形态在 Toolbar 内根据工具切换。
/// 纯标量映射，nonisolated：MainActor 预览与 off-MainActor compositor 共用。
nonisolated enum Thickness {
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

enum MosaicPreparationPhase {
    case idle
    case preparing
    case ready(CaptureImage)
    case failed(stableCode: String)

    var canStart: Bool {
        switch self {
        case .idle, .failed: true
        case .preparing, .ready: false
        }
    }
}

enum EditorDeliveryPhase: Equatable {
    case editing
    case delivering
    case recovery
    case retrying

    var isEditable: Bool {
        if case .editing = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .delivering, .retrying: true
        case .editing, .recovery: false
        }
    }

    var showsRetry: Bool {
        if case .recovery = self { return true }
        return false
    }
}

/// 统一 undo/redo 历史项（M09-04）：一次用户操作对应一条，覆盖栅格插入与
/// 文字 create/edit/move。只存在于 `@MainActor EditorState` 内，不跨 actor，
/// 无需 Sendable（携带非 Sendable 的 `DrawCommand`/`TextAnnotation` 值）。
enum EditorEdit {
    case rasterInsert(DrawCommand)
    case textCreate(TextAnnotation)
    case textEdit(id: UUID, before: String, after: String)
    case textMove(id: UUID, from: CGPoint, to: CGPoint)
}

// MARK: - EditorState

@Observable @MainActor
final class EditorState {
    let original: CaptureImage
    var mosaicPhase: MosaicPreparationPhase = .idle
    private(set) var deliveryPhase: EditorDeliveryPhase = .editing

    var isEditable: Bool { deliveryPhase.isEditable }

    var pixelatedSource: CGImage? {
        guard case .ready(let image) = mosaicPhase else { return nil }
        return image.cgImage
    }

    var isMosaicReady: Bool { pixelatedSource != nil }

    var hasMosaicCommands: Bool {
        commands.contains { command in
            if case .mosaic = command { return true }
            return false
        }
    }

    var commands: [DrawCommand] = []
    /// 统一 undo/redo 历史（M09-04）：覆盖栅格插入与文字 create/edit/move。
    /// `commands`/`textAnnotations` 仍是渲染真相，history 只描述可逆变换。
    private var undoStack: [EditorEdit] = []
    private var redoStack: [EditorEdit] = []
    /// 当前文字编辑事务上下文：进入编辑时捕获，`endEditing` 时据此提交一条 history。
    private var editingIsCreate = false
    private var editingBeforeText: String?
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
        }
    }
    var colorIndex: Int = 0
    var sampledColor: ColorRef?
    var usingSampled: Bool = false
    var thicknessIndex: Int = 1

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var activeColor: ColorRef {
        usingSampled ? (sampledColor ?? .preset(colorIndex)) : .preset(colorIndex)
    }

    init(image: CaptureImage) {
        self.original = image
    }

    func commit(_ cmd: DrawCommand) {
        guard isEditable else { return }
        commands.append(cmd)
        pushUndo(.rasterInsert(cmd))
    }

    func undo() {
        guard isEditable, let edit = undoStack.popLast() else { return }
        revert(edit)
        redoStack.append(edit)
    }

    func redo() {
        guard isEditable, let edit = redoStack.popLast() else { return }
        apply(edit)
        undoStack.append(edit)
    }

    /// 每次真正的 commit 统一清 redo tail（标准撤销栈语义）。
    private func pushUndo(_ edit: EditorEdit) {
        undoStack.append(edit)
        redoStack.removeAll()
    }

    private func apply(_ edit: EditorEdit) {
        switch edit {
        case .rasterInsert(let cmd): commands.append(cmd)
        case .textCreate(let annotation): textAnnotations.append(annotation)
        case .textEdit(let id, _, let after): setText(id: id, to: after)
        case .textMove(let id, _, let to): setOrigin(id: id, to: to)
        }
    }

    private func revert(_ edit: EditorEdit) {
        switch edit {
        case .rasterInsert(let cmd): removeCommand(id: cmd.id)
        case .textCreate(let annotation): removeText(id: annotation.id)
        case .textEdit(let id, let before, _): setText(id: id, to: before)
        case .textMove(let id, let from, _): setOrigin(id: id, to: from)
        }
    }

    private func removeCommand(id: UUID) {
        commands.removeAll { $0.id == id }
    }

    private func removeText(id: UUID) {
        textAnnotations.removeAll { $0.id == id }
    }

    private func setText(id: UUID, to text: String) {
        guard let idx = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[idx].text = text
    }

    private func setOrigin(id: UUID, to point: CGPoint) {
        guard let idx = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[idx].origin = point
    }

    // MARK: - Text annotation operations

    /// 在画布点 P 处创建一条新文字，并立即进入编辑态。
    /// 若已有编辑中的文字，先 endEditing（自动清理空文字）。
    func startNewText(at point: CGPoint) {
        guard isEditable else { return }
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
        editingIsCreate = true
        editingBeforeText = nil
    }

    func updateText(id: UUID, text: String) {
        guard isEditable else { return }
        guard let idx = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[idx].text = text
    }

    func moveText(id: UUID, to point: CGPoint) {
        guard isEditable else { return }
        guard let idx = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        textAnnotations[idx].origin = point
    }

    /// 一次拖动 begin→end 提交一条 `.textMove`（M09-04）。拖动途中的连续
    /// `moveText` 只更新渲染位置、不入 history；无位移不提交。
    func commitTextMove(id: UUID, from: CGPoint, to: CGPoint) {
        guard isEditable, from != to else { return }
        pushUndo(.textMove(id: id, from: from, to: to))
    }

    func enterEditing(id: UUID) {
        guard isEditable else { return }
        // 切换编辑态前先 end 之前的（若有），保证同时只有一条编辑中
        endEditing()
        editingTextID = id
        editingIsCreate = false
        editingBeforeText = textAnnotations.first(where: { $0.id == id })?.text ?? ""
    }

    /// 结束当前编辑并提交一条 history 事务（M09-04）：新建为空→丢弃且无 entry；
    /// 新建非空→一条 `.textCreate`；已有文字内容变化→一条 `.textEdit(before, after)`。
    func endEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        let isCreate = editingIsCreate
        let before = editingBeforeText
        editingIsCreate = false
        editingBeforeText = nil
        guard let idx = textAnnotations.firstIndex(where: { $0.id == id }) else { return }
        let current = textAnnotations[idx].text
        if isCreate {
            if current.isEmpty {
                textAnnotations.remove(at: idx)
            } else {
                pushUndo(.textCreate(textAnnotations[idx]))
            }
        } else if let before, before != current {
            pushUndo(.textEdit(id: id, before: before, after: current))
        }
    }

    // MARK: - Delivery state

    func beginDelivery() -> Bool {
        guard deliveryPhase == .editing else { return false }
        endEditing()
        drafting = nil
        deliveryPhase = .delivering
        return true
    }

    func enterRecovery() {
        deliveryPhase = .recovery
    }

    func beginRetry() -> Bool {
        guard deliveryPhase == .recovery else { return false }
        deliveryPhase = .retrying
        return true
    }

    func returnToEditing() {
        deliveryPhase = .editing
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
