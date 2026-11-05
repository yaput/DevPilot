import DevPilotCore
import Foundation

/// Composition root: the only place that picks concrete storage, credentials and transport.
@MainActor
enum AppContainer {
    static func makeModels() -> (AppModel, ProviderSettingsModel) {
        let isolated = AppDatabase.isIsolated
        let settingsStore = SettingsStore(defaults: isolated ? UserDefaults(suiteName: "dev.devpilot.DevPilot.isolated") ?? .standard : .standard)
        let service = (Bundle.main.bundleIdentifier ?? "dev.devpilot.DevPilot") + (isolated ? ".isolated" : "")
        let credentials = KeychainCredentialStore(service: service)
        let factory = ProviderFactory(credentials: credentials, http: URLSessionHTTPClient())
        let app = AppModel(settingsStore: settingsStore, factory: factory, credentials: credentials)
        let settings = ProviderSettingsModel(app: app, store: settingsStore, credentials: credentials, factory: factory)
        return (app, settings)
    }
}
