import Foundation

/// Caps how many runs of one kind execute at once (e.g. builds, which are heavy on CPU and
/// memory); the rest wait in FIFO order. Waiting is cancellable, and the limit can change
/// while runs are active.
public actor RunLimiter {
    private var limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var activeCount: Int { running }
    public var waitingCount: Int { waiters.count }

    public func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        resumeWaiters()
    }

    /// Runs `work` once a slot is free. `onQueued` reports the position (1-based) if it has
    /// to wait. Cancelling while queued throws `CancellationError` without taking a slot.
    public func withSlot<T: Sendable>(
        onQueued: @Sendable (Int) -> Void = { _ in },
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(onQueued: onQueued)
        defer { release() }
        return try await work()
    }

    private func acquire(onQueued: @Sendable (Int) -> Void) async throws {
        try Task.checkCancellation()
        if running < limit && waiters.isEmpty {
            running += 1
            return
        }
        let id = UUID()
        onQueued(waiters.count + 1)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func release() {
        running -= 1
        resumeWaiters()
    }

    private func resumeWaiters() {
        while running < limit, !waiters.isEmpty {
            let next = waiters.removeFirst()
            running += 1
            next.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
