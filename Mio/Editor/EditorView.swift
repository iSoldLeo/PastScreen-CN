//
//  EditorView.swift
//  Mio
//
//  CH-E3 编辑器 root view。
//  当前阶段：工具栏（视觉完成）+ 截图画布 + 取消 / 完成。工具的实际绘制
//  能力在 CH-E4 起逐批接入（spec §11）。
//

import SwiftUI
import AppKit

struct EditorView: View {
    @State private var state = EditorState()

    let image: CaptureImage
    let onCancel: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(state: state)
            canvas
            footerBar
        }
        .frame(minWidth: 760, minHeight: 760)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var canvas: some View {
        // 当前阶段单层 Image 渲染。CH-E5 起切换到 SwiftUI Canvas API
        // + 矢量文字 overlay（spec §5）。
        // 画布背景用 underPageBackgroundColor（苹果标准画布灰），
        // 跟随系统亮暗，让任意颜色截图都有清晰边界。
        Image(decorative: image.cgImage, scale: image.scale)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(Color(NSColor.underPageBackgroundColor))
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("取消", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("完成", action: onFinish)
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
}
