import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

struct RunLimiterTests {
    @Test func neverExceedsTheLimit() async throws {
        let limiter = RunLimiter(limit: 2)
        let peak = Mutex((current: 0, max: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await limiter.withSlot {
                        peak.withLock { $0.current += 1; $0.max = max($0.max, $0.current) }
                        try await Task.sleep(for: .milliseconds(50))
                        peak.withLock { $0.current -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(peak.withLock { $0.max } == 2)
        #expect(await limiter.activeCount == 0)
    }

    @Test func reportsQueuePositionAndRunsInOrder() async throws {
        let limiter = RunLimiter(limit: 1)
        let gate = Mutex(false)
        let order = Mutex<[Int]>([])
        let positions = Mutex<[Int]>([])
        let first = Task {
            try await limiter.withSlot {
                while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
                order.withLock { $0.append(0) }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        var waiting: [Task<Void, Error>] = []
        for index in 1...2 {
            waiting.append(Task {
                try await limiter.withSlot(onQueued: { position in positions.withLock { $0.append(position) } }) {
                    order.withLock { $0.append(index) }
                }
            })
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await limiter.waitingCount == 2)
        gate.withLock { $0 = true }
        try await first.value
        for task in waiting { try await task.value }
        #expect(order.withLock { $0 } == [0, 1, 2])
        #expect(positions.withLock { $0 } == [1, 2])
    }

    @Test func cancellingAQueuedRunFreesItsPlace() async throws {
        let limiter = RunLimiter(limit: 1)
        let gate = Mutex(false)
        let holder = Task {
            try await limiter.withSlot { while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) } }
        }
        try await Task.sleep(for: .milliseconds(50))
        let ran = Mutex(false)
        let queued = Task { try await limiter.withSlot { ran.withLock { $0 = true } } }
        try await Task.sleep(for: .milliseconds(50))

        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await limiter.waitingCount == 0)
        gate.withLock { $0 = true }
        try await holder.value
        #expect(!ran.withLock { $0 })
        #expect(await limiter.activeCount == 0)
    }

    @Test func raisingTheLimitStartsWaitingRuns() async throws {
        let limiter = RunLimiter(limit: 1)
        let gate = Mutex(false)
        let holder = Task {
            try await limiter.withSlot { while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) } }
        }
        try await Task.sleep(for: .milliseconds(50))
        let started = Mutex(false)
        let queued = Task { try await limiter.withSlot { started.withLock { $0 = true } } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!started.withLock { $0 })

        await limiter.setLimit(2)
        try await queued.value
        #expect(started.withLock { $0 })
        gate.withLock { $0 = true }
        try await holder.value
    }

    @Test func failureReleasesTheSlot() async throws {
        let limiter = RunLimiter(limit: 1)
        await #expect(throws: AgentError.self) {
            try await limiter.withSlot { throw AgentError.failed("x") }
        }
        #expect(await limiter.activeCount == 0)
        #expect(try await limiter.withSlot { 42 } == 42)
    }
}
