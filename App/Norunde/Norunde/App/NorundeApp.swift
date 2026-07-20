import SwiftUI
import AppKit

@main
struct NorundeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
        } label: {
            Label {
                Text("Norunde")
            } icon: {
                Image(systemName: viewModel.runningCount > 0 ? "shippingbox.fill" : "shippingbox")
            }
            .id(viewModel.statusRevision)
        }
        .menuBarExtraStyle(.window)
    }
}
