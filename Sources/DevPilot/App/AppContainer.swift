import DevPilotCore
import Foundation

/// Composition root: the only place that picks concrete storage, credentials and transport.
@MainActor
enum AppContainer {
    static func makeModels() -> (AppModel, ProviderSettingsModel) {
        let settingsStore = SettingsStore()
        let credentials = KeychainCredentialStore(service: Bundle.main.bundleIdentifier ?? "dev.devpilot.DevPilot")
        let factory = ProviderFactory(credentials: credentials, http: URLSessionHTTPClient())
        let app = AppModel(settingsStore: settingsStore, factory: factory)
        let settings = ProviderSettingsModel(app: app, store: settingsStore, credentials: credentials, factory: factory)
        return (app, settings)
    }
}
