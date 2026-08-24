//
//  EditorWindowController.swift
//  Mio
//
//  NSWindowController 标准模式管理编辑器窗口。
//  Cocoa 推荐容器，自带 retain/release 闭环 + showWindow/close 标准生命周期。
//
//  窗口同时拥有唯一 EditorState、马赛克准备 Task 与交付 Task；重位图变换
//  交给 ImageProcessor，sink orchestration交给OutputDeliveryService。
//

import AppKit
import OSLog
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let windowID: EditorWindowID
    private let image: CaptureImage
    private let displayID: CGDirectDisplayID
    private let framePreference: CaptureFramePreference
    private let deliveryPolicy: DeliveryPolicy
    private let capturedAt: CaptureTimestamp
    private let outputDelivery: OutputDeliveryService
    private let imageProcessor: ImageProcessor
    private let feedbackPresenter: CaptureFeedbackPresenting
    private let compositeRenderer: EditorCompositeRenderer
    private unowned let registry: EditorWindowRegistry
    private let editorState: EditorState
    private var mosaicOperationID: UUID?
    private var mosaicTask: Task<Void, Never>?
    private var deliveryOperationID: UUID?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryRecovery: DeliveryRecovery?
    private var eyedropperOperationID: UUID?
    private var eyedropperTask: Task<Void, Never>?
    private var finishWatchdogTask: Task<Void, Never>?
    private var finishStage: FinishStage?

    /// 一次 Done/retry 的子阶段。watchdog 据此决定超时处置：合成/06 前可安全回
    /// 可编辑并报 image-prep 失败；进入 07 后不重开 Done、不改判失败，交由 delivery
    /// task 的 completion 恰好消费一次 07 累计 outcome。
    private enum FinishStage {
        case composing
        case preparing
        case delivering
        case retrying
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "editor.session"
    )

    private struct DeliveryRecovery {
        let request: DeliveryRequest
        let cumulativeOutcome: DeliveryOutcome
    }

    init(
        windowID: EditorWindowID,
        input: EditorInput,
        outputDelivery: OutputDeliveryService,
        imageProcessor: ImageProcessor,
        feedbackPresenter: CaptureFeedbackPresenting,
        compositeRenderer: EditorCompositeRenderer,
        registry: EditorWindowRegistry
    ) {
        self.windowID = windowID
        self.image = input.image
        self.displayID = input.displayID
        self.framePreference = input.framePreference
        self.deliveryPolicy = input.deliveryPolicy
        self.capturedAt = input.capturedAt
        self.outputDelivery = outputDelivery
        self.imageProcessor = imageProcessor
        self.feedbackPresenter = feedbackPresenter
        self.compositeRenderer = compositeRenderer
        self.registry = registry
        let editorState = EditorState(image: input.image)
        self.editorState = editorState

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mio"
        // 红圆 / ⌘W = 取消（不弹「是否保存」对话框，符合 Mio 极简）

        super.init(window: window)
        window.delegate = self

        // SwiftUI 内容
        let view = EditorView(
            state: editorState,
            onCancel: { [weak self] in self?.cancel() },
            onFinish: { [weak self] in self?.finish() },
            onRetryDelivery: { [weak self] in self?.retryPendingDelivery() },
            onRequestMosaic: { [weak self] in self?.requestMosaicSource() },
            onRequestColorSampling: { [weak self] in self?.requestColorSampling() }
        )
        let host = NSHostingController(rootView: view)
        // 让 hosting controller 把 SwiftUI 视图的 fitting size 自动同步到
        // NSWindow.contentMinSize。SwiftUI EditorView 自己有 .frame(minWidth: 760,
        // minHeight: 760) 兜底，所以 fitting size 在 TextField 进出编辑时恒定，
        // 不会触发 contentMinSize 抖动。单一来源（SwiftUI .frame → fitting →
        // contentMinSize），无双层冲突。
        host.sizingOptions = [.minSize]
        window.contentViewController = host

        Self.configureSize(window: window, displayID: input.displayID, image: input.image)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        deliveryTask?.cancel()
        mosaicTask?.cancel()
        eyedropperTask?.cancel()
        finishWatchdogTask?.cancel()
    }

    // MARK: - User actions

    /// Done：在 MainActor 冻结 Sendable 快照 → `EditorCompositeRenderer actor` 做
    /// 全分辨率合成（离开 MainActor）→ ImageProcessor 画框 → OutputDeliveryService
    /// 交付；20s owned watchdog 兜底。partial 缓存同一 request/outcome，后续 Retry
    /// 绝不重新合成或读取当前设置。
    func finish() {
        guard deliveryTask == nil, editorState.beginDelivery() else { return }
        cancelMosaicOperation()
        cancelEyedropperOperation()

        // beginDelivery() 已提交 active text 事务并清 draft；此刻在 MainActor 冻结
        // 一份 Sendable 快照，全分辨率合成移到 EditorCompositeRenderer actor（M09-03）。
        let snapshot = EditorCompositeSnapshot.capture(from: editorState)
        let frameApplication = resolvedFrameApplication(from: framePreference)
        let deliveryPolicy = self.deliveryPolicy
        let compositor = self.compositeRenderer
        let imageProcessor = self.imageProcessor
        let outputDelivery = self.outputDelivery
        let capturedAt = self.capturedAt
        let operationID = UUID()
        deliveryOperationID = operationID
        deliveryRecovery = nil
        startFinishWatchdog(operationID: operationID)

        deliveryTask = Task(
            name: "mio.editor.delivery.\(operationID.uuidString)",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            guard self?.deliveryOperationID == operationID, !Task.isCancelled else { return }
            self?.finishStage = .composing
            do {
                let composed = try await compositor.render(snapshot)
                guard self?.deliveryOperationID == operationID, !Task.isCancelled else { return }
                self?.finishStage = .preparing
                let prepared = try await imageProcessor.prepareImage(
                    ImagePreparationRequest(
                        correlationID: operationID,
                        source: composed,
                        crop: nil,
                        frame: frameApplication
                    )
                )
                guard self?.deliveryOperationID == operationID, !Task.isCancelled else { return }
                self?.finishStage = .delivering
                let request = DeliveryRequest(
                    correlationID: operationID,
                    image: prepared,
                    capturedAt: capturedAt,
                    policy: deliveryPolicy
                )
                let outcome = await outputDelivery.deliver(request)
                guard let self, self.deliveryOperationID == operationID else { return }
                self.completeInitialDelivery(request: request, outcome: outcome)
            } catch {
                guard let self, self.deliveryOperationID == operationID else { return }
                self.clearDeliveryOperation(cancelTask: false)
                self.editorState.returnToEditing()
                self.feedbackPresenter.present(
                    .failed(
                        id: CaptureFeedbackID(rawValue: operationID),
                        failure: .imagePreparationFailed
                    )
                )
            }
        }
    }

    private func completeInitialDelivery(request: DeliveryRequest, outcome: DeliveryOutcome) {
        clearDeliveryOperation(cancelTask: false)
        feedbackPresenter.present(
            .delivered(
                id: CaptureFeedbackID(),
                source: .editorFinish,
                summary: .project(from: outcome),
                soundEnabled: false
            )
        )
        switch outcome.completion {
        case .complete:
            close()
        case .partial:
            deliveryRecovery = DeliveryRecovery(
                request: request,
                cumulativeOutcome: outcome
            )
            editorState.enterRecovery()
        case .failed, .cancelled:
            deliveryRecovery = nil
            editorState.returnToEditing()
        }
    }

    private func retryPendingDelivery() {
        guard
            deliveryTask == nil,
            let recovery = deliveryRecovery,
            editorState.beginRetry()
        else { return }

        let operationID = UUID()
        deliveryOperationID = operationID
        startFinishWatchdog(operationID: operationID)
        let outputDelivery = self.outputDelivery
        deliveryTask = Task(
            name: "mio.editor.delivery.retry.\(operationID.uuidString)",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            guard
                self?.deliveryOperationID == operationID,
                !Task.isCancelled
            else { return }
            self?.finishStage = .retrying
            let outcome = await outputDelivery.retryPendingSinks(
                originalRequest: recovery.request,
                after: recovery.cumulativeOutcome
            )
            guard let self, self.deliveryOperationID == operationID else { return }
            self.clearDeliveryOperation(cancelTask: false)
            self.feedbackPresenter.present(
                .delivered(
                    id: CaptureFeedbackID(),
                    source: .editorFinish,
                    summary: .project(from: outcome),
                    soundEnabled: false
                )
            )
            switch outcome.completion {
            case .complete:
                self.deliveryRecovery = nil
                self.close()
            case .partial:
                self.deliveryRecovery = DeliveryRecovery(
                    request: recovery.request,
                    cumulativeOutcome: outcome
                )
                self.editorState.enterRecovery()
            case .failed, .cancelled:
                preconditionFailure(
                    "A retry from a partial receipt must retain at least one successful sink"
                )
            }
        }
    }

    /// 取消：先使当前operation identity失效，再请求取消；已经提交的sink不回滚。
    func cancel() {
        clearDeliveryOperation(cancelTask: true)
        close()
    }

    // MARK: - NSWindowDelegate

    /// macOS 26 SDK 起 NSWindowDelegate 整体已是 @MainActor 协议，
    /// 类自身也是 @MainActor，可直接同步调 Registry.deregister。
    func windowWillClose(_ notification: Notification) {
        clearDeliveryOperation(cancelTask: true)
        deliveryRecovery = nil
        cancelMosaicOperation()
        cancelEyedropperOperation()
        registry.deregister(id: windowID, controller: self)
    }

    // MARK: - Eyedropper (controller-owned)

    /// 唯一 per-window 屏幕取色 operation。已有 sampler 时 typed no-op，不并发第二个
    /// 系统 sampler。`NSColorSampler` callback 不可被 Task 取消撤销，因此 Task 回到
    /// MainActor 后必须再校验 operation identity 与 editable phase 才写 color。
    private func requestColorSampling() {
        guard editorState.isEditable, eyedropperTask == nil else { return }
        let operationID = UUID()
        eyedropperOperationID = operationID
        eyedropperTask = Task(
            name: "mio.editor.eyedropper.\(operationID.uuidString)",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            let picked = await EyedropperService.pickColor()
            guard let self, self.eyedropperOperationID == operationID else { return }
            self.eyedropperTask = nil
            self.eyedropperOperationID = nil
            guard self.editorState.isEditable, let picked else { return }
            self.editorState.sampledColor = picked
            self.editorState.usingSampled = true
        }
    }

    private func cancelEyedropperOperation() {
        eyedropperOperationID = nil
        eyedropperTask?.cancel()
        eyedropperTask = nil
    }

    // MARK: - Mosaic preparation

    /// This controller permanently owns the single per-window mosaic operation.
    /// Matching ID is checked after the actor hop; closing the window clears the
    /// ID before cancellation so a late result cannot mutate retained UI state.
    private func requestMosaicSource() {
        guard editorState.isEditable, editorState.mosaicPhase.canStart else { return }

        mosaicTask?.cancel()
        let operationID = UUID()
        mosaicOperationID = operationID
        editorState.mosaicPhase = .preparing
        let source = image
        let processor = imageProcessor

        mosaicTask = Task(
            name: "mio.editor.mosaic.\(operationID.uuidString)",
            priority: .userInitiated
        ) { @MainActor [weak self] in
            do {
                let pixelated = try await processor.makePixelatedSource(
                    from: source,
                    correlationID: operationID
                )
                guard let self, self.mosaicOperationID == operationID else { return }
                self.mosaicOperationID = nil
                self.mosaicTask = nil
                self.editorState.mosaicPhase = .ready(pixelated)
            } catch is CancellationError {
                guard let self, self.mosaicOperationID == operationID else { return }
                self.mosaicOperationID = nil
                self.mosaicTask = nil
                self.editorState.mosaicPhase = .idle
            } catch let error as ImageProcessingError {
                guard let self, self.mosaicOperationID == operationID else { return }
                self.mosaicOperationID = nil
                self.mosaicTask = nil
                self.editorState.mosaicPhase = .failed(stableCode: error.stableCode)
            } catch {
                guard let self, self.mosaicOperationID == operationID else { return }
                self.mosaicOperationID = nil
                self.mosaicTask = nil
                self.editorState.mosaicPhase = .failed(stableCode: "unexpected")
            }
        }
    }

    private func cancelMosaicOperation() {
        mosaicOperationID = nil
        mosaicTask?.cancel()
        mosaicTask = nil
        if case .preparing = editorState.mosaicPhase {
            editorState.mosaicPhase = .failed(stableCode: "delivery_transition")
        }
    }

    /// R09-D1: invalidate identity before cancellation so a late await result
    /// cannot mutate or reopen a closing window. Committed sink effects remain
    /// represented by the service outcome and are not claimed to roll back.
    private func clearDeliveryOperation(cancelTask: Bool) {
        deliveryOperationID = nil
        finishStage = nil
        let task = deliveryTask
        deliveryTask = nil
        finishWatchdogTask?.cancel()
        finishWatchdogTask = nil
        if cancelTask {
            task?.cancel()
        }
    }

    /// F06: 一次 Done/retry 的 09-owned deadline（20s，与 03 finalizing 上界一致；
    /// 覆盖全分辨率合成 + 06 + 07 的用户可见等待）。到时先失效 identity 再取消
    /// operation，回到可编辑并发 typed feedback；已提交的不可逆 sink 由 07 outcome
    /// 表达，本处不重开窗、不伪称回滚。正常终态经 `clearDeliveryOperation` 取消本 watchdog。
    private func startFinishWatchdog(operationID: UUID) {
        finishWatchdogTask?.cancel()
        finishWatchdogTask = Task(
            name: "mio.editor.finish.watchdog.\(operationID.uuidString)",
            priority: .utility
        ) { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard let self, self.deliveryOperationID == operationID else { return }
            switch self.finishStage {
            case .delivering, .retrying:
                // 已进入 07：不重开 Done、不改判 imagePrep 失败、不清 identity。只请求
                // 取消让 07 收敛，其累计 outcome 由 delivery task 的 completion 恰好消费
                // 一次（operationID 仍匹配）；committed sink 由 07 outcome 表达，不伪称回滚。
                Self.logger.notice(
                    "event=editor.finish.watchdog window_id=\(self.windowID.rawValue.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) stage=delivering result=cancel_requested_await_receipt"
                )
                self.deliveryTask?.cancel()
            case .composing, .preparing, .none:
                // 合成 / 06 阶段超时：尚无不可逆 sink，安全回可编辑并 typed image-prep failure。
                Self.logger.notice(
                    "event=editor.finish.watchdog window_id=\(self.windowID.rawValue.uuidString, privacy: .public) operation_id=\(operationID.uuidString, privacy: .public) stage=preparing result=image_preparation_timeout"
                )
                self.clearDeliveryOperation(cancelTask: true)
                self.editorState.returnToEditing()
                self.feedbackPresenter.present(
                    .failed(
                        id: CaptureFeedbackID(rawValue: operationID),
                        failure: .imagePreparationFailed
                    )
                )
            }
        }
    }

    // MARK: - Sizing

    /// 默认尺寸（PRODUCT v4 §3.4）—— 只在窗口初始化时算一次，之后用户随意拖。
    ///
    /// 1. 窗口高度 = 屏幕可见区高度 × 90%
    /// 2. 此高度下截图能显示的宽度 = (高度 - chrome - canvas padding) × 截图长宽比
    /// 3. 窗口宽度 = max(截图显示宽度 + canvas padding, 760pt)
    /// 4. 居中显示在截图所在屏
    ///
    /// chromeHeight 是工具栏 + 分隔线 + footer 的估算高度。改 EditorView 排版
    /// 后必须同步更新此值。当前布局实测约 98pt：
    ///   - EditorToolbar:      padding 10+10 + content ~26 + divider 1 = 47
    ///   - footer:             padding 10+10 + button height ~30 + divider 1 = 51
    /// minSize = 760 × 760，工具栏自然下限。
    private static let chromeHeight: CGFloat = 98
    private static let canvasPadding: CGFloat = 32  // EditorView.canvas .padding(16) × 2

    private static func configureSize(
        window: NSWindow,
        displayID: CGDirectDisplayID,
        image: CaptureImage
    ) {
        let screen = NSScreen.screens.first { ns in
            let id = ns.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return id == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first

        let visible = screen?.visibleFrame ?? CGRect(x: 100, y: 100, width: 1280, height: 800)
        let height = visible.height * 0.9

        // 反算图像在 90% 高度窗口里能显示的宽度。
        let canvasInnerHeight = max(height - chromeHeight - canvasPadding, 1)
        let aspectRatio = image.size.height > 0
            ? image.size.width / image.size.height
            : 1
        let imageDisplayWidth = canvasInnerHeight * aspectRatio

        let width = max(imageDisplayWidth + canvasPadding, 760)
        let x = visible.midX - width / 2
        let y = visible.midY - height / 2
        window.setFrame(CGRect(x: x, y: y, width: width, height: height), display: false)
        // minSize 由 NSHostingController.sizingOptions = [.minSize] 自动管理：
        // SwiftUI 视图的 .frame(minWidth: 760, minHeight: 760) 会被同步推到
        // window.contentMinSize，不需要在此手动赋值。两层独立赋值会在临界值抖动。
    }
}
