//
//  EditorState.swift
//  Mio
//
//  编辑器跨工具共享的 UI 状态 + 工具集 / 颜色集模型。
//
//  当前阶段（CH-E2）只承载工具栏 UI 状态；CH-E3 起扩展为完整的命令栈
//  + 矢量文字层 + baseline cache（spec §4/§5）。
//

import Foundation
import SwiftUI

/// 编辑器工具集（PRODUCT v4 §3.4 锁定，6 项不可扩展）。
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
        case .rectangle: "矩形"
        case .ellipse:   "椭圆"
        case .arrow:     "箭头"
        case .pencil:    "画笔"
        case .mosaic:    "马赛克"
        case .text:      "文字"
        }
    }
}

/// 编辑器 7 色预设（PRODUCT v4 §3.4 锁定）。
let editorPresetColors: [(name: String, color: Color)] = [
    ("red",    Color(red: 0.92, green: 0.20, blue: 0.18)),
    ("orange", Color(red: 0.98, green: 0.65, blue: 0.16)),
    ("green",  Color(red: 0.20, green: 0.78, blue: 0.42)),
    ("blue",   Color(red: 0.10, green: 0.50, blue: 0.96)),
    ("white",  .white),
    ("gray",   Color(red: 0.55, green: 0.55, blue: 0.55)),
    ("black",  .black),
]

@Observable @MainActor
final class EditorState {
    var tool: EditorTool = .rectangle
    var colorIndex: Int = 0
    var thickness: Int = 1   // 0=细 1=中 2=粗

    /// 撤销 / 恢复按钮的可用性。当前阶段无命令栈，恒为 false；
    /// CH-E3 起接入命令栈后改为派生自 commands.isEmpty / redoQueue.isEmpty。
    var canUndo: Bool = false
    var canRedo: Bool = false

    /// 最近一次屏幕取色结果。nil 表示尚未取色。
    /// CH-E5/6 起接入 NSColorSampler 真 API；当前阶段保留 mockup 的随机模拟。
    var sampledColor: Color? = nil
    /// 当前激活色：true = 用最近取色，false = 用预设第 colorIndex
    var usingSampled: Bool = false
}
