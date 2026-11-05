import AppKit
import SwiftUI

@main
struct DevPilotApp: App {
    @State private var model: AppModel
    @State private var providerSettings: ProviderSettingsModel

    init() {
        let (model, providerSettings) = AppContainer.makeModels()
        _model = State(initialValue: model)
        _providerSettings = State(initialValue: providerSettings)
    }

    var body: some Scene {
        Window("DevPilot", id: AppWindow.dashboard) {
            DashboardView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    IsolatedCapture.install(model: model)
                    await model.start()
                }
        }

        WindowGroup("Changes", id: AppWindow.changes, for: String.self) { $ticketID in
            if let ticketID {
                ChangesView(ticketID: ticketID)
                    .environment(model)
                    .frame(minWidth: 900, minHeight: 560)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(providerSettings)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            let needsYou = model.tickets.filter { model.lane(of: $0.id) == .needsYou }.count
            Image(systemName: needsYou > 0 ? "paperplane.circle.fill" : "paperplane")
            if needsYou > 0 {
                Text("\(needsYou)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

enum AppWindow {
    static let dashboard = "dashboard"
    static let changes = "changes"
}
