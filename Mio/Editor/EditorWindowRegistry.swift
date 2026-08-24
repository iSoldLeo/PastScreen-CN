//
//  EditorWindowRegistry.swift
//  Mio
//
//  路径 D（高级窗口截图）的编辑器窗口注册表。
//
//  - 每张截图独立 NSWindow，并行编辑互不干扰（PRODUCT v3 §3.4）
//  - Registry 强引用 NSWindowController，避免被 GC
//  - windowWillClose 时由 controller 自身回调 deregister 释放引用
//  - 取消（红圆 / ⌘W） = identity失效后取消owned delivery Task并关窗
//  - 完成 = controller先走ImageProcessor，再走OutputDeliveryService
//

import AppKit
import OSLog

/// 稳定的每窗口身份，用于日志、deregister 校验与统一 shutdown。
nonisolated struct EditorWindowID: Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// 09 handoff 的**窄值边界**（F08/90）：只带 Editor 实际需要的语义字段
/// （frame 偏好 + 交付 policy + 冻结时间戳 + 图与所在屏），不含 sound 等本模块
/// 不使用的偏好。
nonisolated struct EditorInput: Sendable {
    let image: CaptureImage
    let displayID: CGDirectDisplayID
    let framePreference: CaptureFramePreference
    let deliveryPolicy: DeliveryPolicy
    let capturedAt: CaptureTimestamp
}

/// typed open 失败：registry 已 stopped（app 正在终止）时拒绝新 open。
nonisolated enum EditorOpenError: Error, Sendable, Equatable {
    case stopped
}

@MainActor
final class EditorWindowRegistry {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "editor.registry"
    )

    /// 强引用所有打开的编辑器窗口控制器，按稳定 `EditorWindowID` 管理。
    private var controllers: [EditorWindowID: EditorWindowController] = [:]
    private var isStopped = false
    private let imageProcessor: ImageProcessor
    private let outputDelivery: OutputDeliveryService
    private let feedbackPresenter: CaptureFeedbackPresenting
    private let compositeRenderer: EditorCompositeRenderer

    init(
        imageProcessor: ImageProcessor,
        outputDelivery: OutputDeliveryService,
        feedbackPresenter: CaptureFeedbackPresenting,
        compositeRenderer: EditorCompositeRenderer
    ) {
        self.imageProcessor = imageProcessor
        self.outputDelivery = outputDelivery
        self.feedbackPresenter = feedbackPresenter
        self.compositeRenderer = compositeRenderer
    }

    /// 入参提供 displayID 用于按截图所在屏计算 70% 默认尺寸；
    /// preferences 是 capture accepted 时冻结的语义值；Editor Done 只在
    /// 最终 frame request 时解析 `.auto`，保存目录则由当次 lease 决定。
    @discardableResult
    func open(_ input: EditorInput) throws -> EditorWindowID {
        guard !isStopped else {
            Self.logger.notice("event=editor.open result=rejected_stopped")
            throw EditorOpenError.stopped
        }
        let windowID = EditorWindowID()
        let controller = EditorWindowController(
            windowID: windowID,
            input: input,
            outputDelivery: outputDelivery,
            imageProcessor: imageProcessor,
            feedbackPresenter: feedbackPresenter,
            compositeRenderer: compositeRenderer,
            registry: self
        )
        controllers[windowID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // 用户主动从 hotkey 触发到达此处，需要看到窗口和编辑能力。
        // 与路径 A/B「不抢焦点」不冲突——A/B 的不抢焦点是为了不污染
        // 冻结底图，编辑器是用户主动到达的下一阶段。
        NSApp.activate(ignoringOtherApps: true)
        Self.logger.info(
            "event=editor.open result=opened window_id=\(windowID.rawValue.uuidString, privacy: .public) open_count=\(self.controllers.count, privacy: .public)"
        )
        return windowID
    }

    /// 由 `EditorWindowController` 在 windowWillClose 时回调；同时核对 ID 与
    /// 对象 identity，防止陈旧 controller 误删同 ID 的新条目。
    func deregister(id: EditorWindowID, controller: EditorWindowController) {
        guard controllers[id] === controller else { return }
        controllers.removeValue(forKey: id)
    }

    /// 由 01 `AppServices.stop` 同步调用（12 只把 lifecycle 交给 01）。标记
    /// stopped 拒绝新 open，快照后逐个走与普通 close 相同的 cleanup；幂等。
    func stop(reason: AppStopReason) {
        guard !isStopped else { return }
        isStopped = true
        // 快照后逐个走普通 close → windowWillClose → deregister 的正常路径，让
        // remaining 是真实注销结果，而不是预先清表制造的零计数。
        let snapshot = controllers
        for (_, controller) in snapshot {
            controller.close()
        }
        let residue = controllers.count
        if residue > 0 {
            // 某窗未经正常 close 路径注销：记 fault 并安全强清，不谎报归零。
            controllers.removeAll()
            Self.logger.fault(
                "event=editor.registry.stop reason=\(reason.logValue, privacy: .public) closed_count=\(snapshot.count, privacy: .public) residue=\(residue, privacy: .public) result=residue_force_cleared"
            )
        } else {
            Self.logger.info(
                "event=editor.registry.stop reason=\(reason.logValue, privacy: .public) closed_count=\(snapshot.count, privacy: .public) remaining=0 result=all_deregistered"
            )
        }
    }
}
