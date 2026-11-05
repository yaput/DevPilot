import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

struct BuildGateTests {
    @Test func neverExceedsTheLimit() async throws {
        let gate = BuildGate(limit: 2, pressure: { .normal })
        let peak = Mutex((current: 0, max: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await gate.run {
                        peak.withLock { $0.current += 1; $0.max = max($0.max, $0.current) }
                        try await Task.sleep(for: .milliseconds(40))
                        peak.withLock { $0.current -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(peak.withLock { $0.max } == 2)
        #expect(await gate.executingCount == 0)
    }

    @Test func underMemoryPressureRunsOneAtATime() async throws {
        let gate = BuildGate(limit: 4, pressure: { .warning }, pollInterval: .milliseconds(10))
        let peak = Mutex((current: 0, max: 0))
        let waits = Mutex(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await gate.run(onWait: { _ in waits.withLock { $0 += 1 } }) {
                        peak.withLock { $0.current += 1; $0.max = max($0.max, $0.current) }
                        try await Task.sleep(for: .milliseconds(40))
                        peak.withLock { $0.current -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        // One is always admitted, so other apps' memory use cannot stall DevPilot.
        #expect(peak.withLock { $0.max } == 1)
        #expect(waits.withLock { $0 } >= 1)
    }

    @Test func pressureEasingAdmitsWaitingCommands() async throws {
        let level = Mutex(MemoryPressure.critical)
        let gate = BuildGate(limit: 2, pressure: { level.withLock { $0 } }, pollInterval: .milliseconds(10))
        let release = Mutex(false)
        let holder = Task {
            try await gate.run { while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) } }
        }
        try await Task.sleep(for: .milliseconds(50))
        let ran = Mutex(false)
        let waiting = Task { try await gate.run { ran.withLock { $0 = true } } }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!ran.withLock { $0 })

        level.withLock { $0 = .normal }
        try await waiting.value
        #expect(ran.withLock { $0 })
        release.withLock { $0 = true }
        try await holder.value
    }

    @Test func cancellingWhileWaitingForMemorySkipsTheWork() async throws {
        let gate = BuildGate(limit: 2, pressure: { .warning }, pollInterval: .milliseconds(10))
        let release = Mutex(false)
        let holder = Task {
            try await gate.run { while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) } }
        }
        try await Task.sleep(for: .milliseconds(50))
        let ran = Mutex(false)
        let waiting = Task { try await gate.run { ran.withLock { $0 = true } } }
        try await Task.sleep(for: .milliseconds(50))

        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!ran.withLock { $0 })
        release.withLock { $0 = true }
        try await holder.value
        #expect(await gate.executingCount == 0)
    }

    @Test func failingWorkFreesItsPlace() async throws {
        struct Boom: Error {}
        let gate = BuildGate(limit: 1, pressure: { .normal })
        await #expect(throws: Boom.self) { try await gate.run { throw Boom() } }
        #expect(await gate.executingCount == 0)
        let value = try await gate.run { 42 }
        #expect(value == 42)
    }

    @Test func reportsTheRunningCount() async throws {
        let gate = BuildGate(limit: 2, pressure: { .normal })
        let seen = Mutex<[Int]>([])
        await gate.observe { count in seen.withLock { $0.append(count) } }
        try await gate.run { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.withLock { $0 } == [0, 1, 0])
    }

    @Test func readsTheSystemPressure() {
        // Whatever the machine's state, the sysctl must be readable and map to a known level.
        #expect([MemoryPressure.normal, .warning, .critical].contains(MemoryPressure.current()))
    }
}

struct AgentSettingsMigrationTests {
    @Test func theOldInvestigationLimitBecomesTheAgentLimit() throws {
        let old = #"{"maxParallelInvestigations": 6, "maxParallelBuilds": 3}"#
        let settings = try JSONDecoder().decode(AgentSettings.self, from: Data(old.utf8))
        #expect(settings.maxParallelAgents == 6)
        #expect(settings.maxParallelBuilds == 3)

        let roundTrip = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.maxParallelAgents == 6)
    }
}

struct ProcessQoSTests {
    @Test func childProcessesRunAtUtilityQoSUnlessAsked() async throws {
        // `ps -o pri` of the child itself: utility QoS lowers the scheduling priority.
        func priority(_ qos: qos_class_t?) async throws -> Int {
            let result = try await ProcessRunner.run(ProcessRequest(
                executable: URL(filePath: "/bin/sh"), arguments: ["-c", "ps -o pri= -p $$"],
                workingDirectory: URL(filePath: "/tmp"), environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(10), qualityOfService: qos
            ))
            return Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        let utility = try await priority(QOS_CLASS_UTILITY)
        let standard = try await priority(nil)
        #expect(utility > 0 && standard > 0)
        #expect(utility < standard)
    }
}
