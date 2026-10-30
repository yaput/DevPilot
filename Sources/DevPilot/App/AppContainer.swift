import DevPilotCore
import Foundation

/// Composition root: the only place that decides which concrete providers and storage are used.
@MainActor
enum AppContainer {
    static func makeModel() -> AppModel {
        // M1 uses fixture providers. They get their own database file so mock tickets never
        // mix with real ones once the Shortcut/Jira adapters land.
        let providers: [any TicketProvider] = [
            MockTicketProvider.sample(.shortcut),
            MockTicketProvider.sample(.jira),
        ]
        let url = AppDatabase.defaultDirectory.appending(path: "devpilot-mock.sqlite")
        do {
            let database = try AppDatabase.onDisk(at: url)
            return AppModel(
                orchestrator: WorkflowOrchestrator(database: database, providers: providers),
                databaseLocation: url.path
            )
        } catch {
            // An in-memory database only fails on a schema bug, which tests catch.
            let database = try! AppDatabase.inMemory()
            let model = AppModel(
                orchestrator: WorkflowOrchestrator(database: database, providers: providers),
                databaseLocation: "In-memory (changes will not be saved)"
            )
            model.lastError = "Could not open \(url.path): \(error.localizedDescription). Using a temporary in-memory database."
            return model
        }
    }
}
