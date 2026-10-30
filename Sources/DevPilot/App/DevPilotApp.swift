import AppKit
import SwiftUI

@main
struct DevPilotApp: App {
    @State private var model = AppContainer.makeModel()

    var body: some Scene {
        Window("DevPilot", id: AppWindow.dashboard) {
            DashboardView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.pendingApprovalCount > 0 ? "paperplane.circle.fill" : "paperplane")
        }
    }
}

enum AppWindow {
    static let dashboard = "dashboard"
}
