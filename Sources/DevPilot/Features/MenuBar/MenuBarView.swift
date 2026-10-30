import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.runningCount == 0 ? "Idle" : "\(model.runningCount) run(s) in progress")
        Text(model.pendingApprovalCount == 1 ? "1 plan awaiting approval" : "\(model.pendingApprovalCount) plans awaiting approval")
        Divider()
        Button("Open Dashboard") {
            openWindow(id: AppWindow.dashboard)
            NSApp.activate()
        }
        .keyboardShortcut("d")
        Button("Refresh Tickets") {
            Task { await model.refresh() }
        }
        .disabled(model.isSyncing)
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Button("Quit DevPilot") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
