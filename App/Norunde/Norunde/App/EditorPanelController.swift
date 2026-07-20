import AppKit
import SwiftUI

/// Hosts the project editor in a real NSPanel.
/// Open/close is driven by AppViewModel directly — MenuBarExtra popover is often
/// already dismissed, so View `.onChange` cannot be trusted alone.
@MainActor
final class EditorPanelController: NSObject, NSWindowDelegate {
    static let shared = EditorPanelController()

    private var panel: NSPanel?
    private weak var viewModel: AppViewModel?
    private var isClosing = false

    var hostWindow: NSWindow? { panel }

    private override init() {
        super.init()
    }

    func show(viewModel: AppViewModel) {
        self.viewModel = viewModel

        if let panel {
            panel.contentViewController = makeHosting(viewModel)
            updateTitle(for: viewModel)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = makeHosting(viewModel)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above MenuBarExtra content so sheets / open panels aren't buried.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentViewController = hosting
        panel.delegate = self
        panel.setContentSize(NSSize(width: 640, height: 640))
        panel.center()

        self.panel = panel
        updateTitle(for: viewModel)
        // Hide MenuBarExtra content only (keep status icon).
        DirectoryPicker.dismissMenuBarContentWindows(keeping: panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }

        if let panel {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        viewModel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        if let viewModel, viewModel.isEditorPresented {
            viewModel.isEditorPresented = false
            viewModel.bannerError = nil
        }
        viewModel = nil
    }

    private func makeHosting(_ viewModel: AppViewModel) -> NSViewController {
        let root = ProjectEditorView()
            .environmentObject(viewModel)
        return NSHostingController(rootView: root)
    }

    private func updateTitle(for viewModel: AppViewModel) {
        switch viewModel.editorMode {
        case .create:
            panel?.title = "导入项目"
        case .edit:
            panel?.title = "编辑项目"
        }
    }
}
