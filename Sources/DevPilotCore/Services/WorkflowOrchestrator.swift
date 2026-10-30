import Foundation

public struct ProviderSyncResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case synced(ticketCount: Int)
        case failed(message: String)
    }

    public let kind: TicketProviderKind
    public let outcome: Outcome
    public let finishedAt: Date
}

/// Coordinates providers and persistence. Exposes only user-initiated actions;
/// agent-driven transitions are added with the Codex runner in M3/M4.
public final class WorkflowOrchestrator: Sendable {
    public let database: AppDatabase
    private let providers: [any TicketProvider]

    public init(database: AppDatabase, providers: [any TicketProvider]) {
        self.database = database
        self.providers = providers
    }

    public var providerKinds: [TicketProviderKind] { providers.map(\.kind) }

    /// Syncs the given providers (all when nil) concurrently. One provider failing
    /// does not prevent the others from syncing.
    public func sync(_ kinds: Set<TicketProviderKind>? = nil) async -> [ProviderSyncResult] {
        let selected = providers.filter { kinds?.contains($0.kind) ?? true }
        let database = self.database
        return await withTaskGroup(of: ProviderSyncResult.self) { group in
            for provider in selected {
                group.addTask {
                    do {
                        let tickets = try await provider.assignedTickets()
                        if let foreign = tickets.first(where: { $0.provider != provider.kind }) {
                            throw TicketProviderError.invalidResponse(
                                "\(provider.kind.displayName) returned ticket \(foreign.id) from another provider"
                            )
                        }
                        try await database.recordSync(tickets, for: provider.kind)
                        return ProviderSyncResult(kind: provider.kind, outcome: .synced(ticketCount: tickets.count), finishedAt: Date())
                    } catch {
                        return ProviderSyncResult(kind: provider.kind, outcome: .failed(message: error.localizedDescription), finishedAt: Date())
                    }
                }
            }
            var results: [ProviderSyncResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.kind < $1.kind }
        }
    }

    public func select(ticketID: String) async throws {
        try await database.transition(ticketID: ticketID, to: .selected, message: "Selected by user")
    }

    public func cancel(ticketID: String) async throws {
        try await database.transition(ticketID: ticketID, to: .cancelled, message: "Cancelled by user")
    }

    /// Call once at launch. Anything that was running when the app stopped is marked failed.
    @discardableResult
    public func recoverInterruptedRuns() async throws -> [String] {
        try await database.failInterruptedRuns(message: "Interrupted: DevPilot stopped while this run was in progress")
    }
}
