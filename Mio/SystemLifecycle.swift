//
//  SystemLifecycle.swift
//  Mio
//
//  Module-12 system lifecycle source (M12-03). Observes the four NSWorkspace
//  sleep/wake/session notifications and relays a pure `SystemLifecycleEvent`
//  enum to a single 01-owned handler. It never hands a `Notification`,
//  `NSWorkspace` or observer token to any feature (§8.4).
//
//  Display-topology change and app termination are NOT workspace events and are
//  deliberately absent here: 01 receives those from `NSApplication` /
//  `applicationWillTerminate` and routes them to the same 03 cancel input.
//

import AppKit

nonisolated enum SystemLifecycleEvent: Sendable, Equatable {
    case willSleep
    case didWake
    case sessionDidResignActive
    case sessionDidBecomeActive
}

@MainActor
final class SystemLifecycleMonitor {
    private var tokens: [NSObjectProtocol] = []
    private var handler: (@MainActor (SystemLifecycleEvent) -> Void)?

    /// Idempotent: a second `start` without an intervening `stop` is ignored.
    func start(_ handler: @escaping @MainActor (SystemLifecycleEvent) -> Void) {
        guard tokens.isEmpty else { return }
        self.handler = handler
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.willSleepNotification, emitting: .willSleep)
        observe(center, NSWorkspace.didWakeNotification, emitting: .didWake)
        observe(center, NSWorkspace.sessionDidResignActiveNotification, emitting: .sessionDidResignActive)
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification, emitting: .sessionDidBecomeActive)
    }

    /// Idempotent teardown.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
        handler = nil
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        emitting event: SystemLifecycleEvent
    ) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard Thread.isMainThread else { return }
            // SAFETY: NSWorkspace posts on OperationQueue.main; the runtime guard
            // verifies the contract before MainActor entry. Only the pure enum is
            // relayed — the Notification never escapes this block.
            MainActor.assumeIsolated {
                self?.handler?(event)
            }
        })
    }
}
