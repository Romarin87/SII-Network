import AppKit
import SwiftUI

struct FloatingWindowAccessor: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = alwaysOnTop ? .floating : .normal
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.isReleasedWhenClosed = false
        }
    }
}
