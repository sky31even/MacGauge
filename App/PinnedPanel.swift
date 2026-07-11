import AppKit
import SwiftUI

// Borderless floating panel pinned to the top-right corner of the screen,
// shown semi-transparent above other windows.
@MainActor
final class PinnedPanelController {
    static let shared = PinnedPanelController()

    private var panel: NSPanel?

    func show(engine: StatsEngine) {
        if panel == nil {
            let hosting = NSHostingView(rootView: CompactStatusView().environmentObject(engine))
            hosting.frame.size = hosting.fittingSize

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: hosting.frame.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.alphaValue = 1
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.contentView = hosting
            self.panel = panel
        }
        positionTopRight()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionTopRight() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - 12,
            y: visible.maxY - panel.frame.height - 12
        ))
    }
}
