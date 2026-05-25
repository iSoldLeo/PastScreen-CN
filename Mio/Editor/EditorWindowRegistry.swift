//
//  EditorWindowRegistry.swift
//  Mio
//
//  路径 D（高级窗口截图）的编辑器窗口注册表。
//
//  - 每张截图独立 NSWindow，并行编辑互不干扰（PRODUCT v3 §3.4）
//  - Registry 强引用 NSWindowController，避免被 GC
//  - windowWillClose 时由 controller 自身回调 deregister 释放引用
//  - 取消（红圆 / ⌘W） = 直接关窗，不调 finishOutput
//  - 完成 = controller.finish() 内部走 finishOutput → 关窗
//

import AppKit

@MainActor
final class EditorWindowRegistry {
    static let shared = EditorWindowRegistry()

    /// 强引用所有打开的编辑器窗口控制器。key 用 ObjectIdentifier
    /// 而非 UUID — 控制器自身的引用 identity 已经唯一。
    private var controllers: [ObjectIdentifier: EditorWindowController] = [:]

    private init() {}

    /// 入参提供 displayID 用于按截图所在屏计算 70% 默认尺寸；
    /// config 提供 saveToFile / 剪贴板等输出策略，与路径 A/B 一致。
    func open(
        image: CaptureImage,
        displayID: CGDirectDisplayID,
        config: CaptureConfiguration,
        pipeline: CapturePipeline
    ) {
        let controller = EditorWindowController(
            image: image,
            displayID: displayID,
            config: config,
            pipeline: pipeline
        )
        controllers[ObjectIdentifier(controller)] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // 用户主动从 hotkey 触发到达此处，需要看到窗口和编辑能力。
        // 与路径 A/B「不抢焦点」不冲突——A/B 的不抢焦点是为了不污染
        // 冻结底图，编辑器是用户主动到达的下一阶段。
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 由 EditorWindowController 在 windowWillClose 时回调。
    func deregister(_ controller: EditorWindowController) {
        controllers.removeValue(forKey: ObjectIdentifier(controller))
    }
}
