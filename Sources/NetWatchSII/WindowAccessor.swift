import AppKit
import SwiftUI

struct FloatingWindowAccessor: NSViewRepresentable {
    let alwaysOnTop: Bool
    let onVisibilityChange: (Bool) -> Void

    init(
        alwaysOnTop: Bool,
        onVisibilityChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.alwaysOnTop = alwaysOnTop
        self.onVisibilityChange = onVisibilityChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibilityChange: onVisibilityChange)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.update(alwaysOnTop: alwaysOnTop, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.onVisibilityChange = onVisibilityChange
        nsView.update(alwaysOnTop: alwaysOnTop, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: WindowProbeView, coordinator: Coordinator) {
        coordinator.detach(reportHidden: true)
    }

    final class WindowProbeView: NSView {
        private var alwaysOnTop = true
        private weak var visibilityCoordinator: Coordinator?

        func update(alwaysOnTop: Bool, coordinator: Coordinator) {
            self.alwaysOnTop = alwaysOnTop
            visibilityCoordinator = coordinator
            configureCurrentWindow()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureCurrentWindow()
        }

        private func configureCurrentWindow() {
            guard let window else {
                visibilityCoordinator?.detach(reportHidden: true)
                return
            }
            window.level = alwaysOnTop ? .floating : .normal
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.isReleasedWhenClosed = false
            visibilityCoordinator?.attach(to: window)
        }
    }

    final class Coordinator {
        var onVisibilityChange: (Bool) -> Void

        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var lastReportedVisibility: Bool?
        private var windowIsClosing = false

        init(onVisibilityChange: @escaping (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
        }

        func attach(to newWindow: NSWindow) {
            if window === newWindow {
                DispatchQueue.main.async { [weak self] in
                    self?.reportCurrentVisibility()
                }
                return
            }

            detach(reportHidden: false)
            window = newWindow
            windowIsClosing = false

            let center = NotificationCenter.default
            let refreshNotifications: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didExposeNotification
            ]
            for name in refreshNotifications {
                observers.append(
                    center.addObserver(
                        forName: name,
                        object: newWindow,
                        queue: .main
                    ) { [weak self] notification in
                        guard let self else { return }
                        if notification.name == NSWindow.didBecomeKeyNotification
                            || notification.name == NSWindow.didDeminiaturizeNotification
                            || notification.name == NSWindow.didExposeNotification {
                            self.windowIsClosing = false
                        }
                        self.reportCurrentVisibility()
                    }
                )
            }
            observers.append(
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: newWindow,
                    queue: .main
                ) { [weak self] _ in
                    self?.windowIsClosing = true
                    self?.report(false)
                }
            )

            DispatchQueue.main.async { [weak self] in
                self?.reportCurrentVisibility()
            }
        }

        func detach(reportHidden: Bool) {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            window = nil
            windowIsClosing = false
            if reportHidden { report(false) }
        }

        private func reportCurrentVisibility() {
            guard !windowIsClosing else {
                report(false)
                return
            }
            guard let window else {
                report(false)
                return
            }
            report(window.isVisible && !window.isMiniaturized)
        }

        private func report(_ isVisible: Bool) {
            guard lastReportedVisibility != isVisible else { return }
            lastReportedVisibility = isVisible
            onVisibilityChange(isVisible)
        }

        deinit {
            detach(reportHidden: false)
        }
    }
}
