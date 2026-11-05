import Darwin
import Foundation

/// macOS's memory pressure, as `kern.memorystatus_vm_pressure_level` reports it.
public enum MemoryPressure: Int32, Sendable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func current() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: level) ?? .normal
    }

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Admits the heavy local commands of a run (setup and validation), as opposed to the agent's
/// thinking, which waits on the network. At most `limit` run at once; while macOS reports memory
/// pressure, a command waits until the others finish, so builds queue instead of swapping. One
/// command is always admitted, so pressure from other apps cannot stall DevPilot forever.
public actor BuildGate {
    private let limiter: RunLimiter
    private let pressure: @Sendable () -> MemoryPressure
    private let pollInterval: Duration
    /// Commands past the memory check, running now.
    private var executing = 0 {
        didSet { observer?(executing) }
    }
    private var observer: (@Sendable (Int) -> Void)?

    public init(
        limit: Int,
        pressure: @escaping @Sendable () -> MemoryPressure = MemoryPressure.current,
        pollInterval: Duration = .seconds(5)
    ) {
        limiter = RunLimiter(limit: limit)
        self.pressure = pressure
        self.pollInterval = pollInterval
    }

    public var executingCount: Int { executing }

    /// Called with the number of running commands whenever it changes.
    public func observe(_ handler: @escaping @Sendable (Int) -> Void) {
        observer = handler
        handler(executing)
    }

    public func setLimit(_ limit: Int) async {
        await limiter.setLimit(limit)
    }

    /// Runs `work` once admitted. `onWait` explains any wait (for the run's progress lines).
    /// Cancelling while waiting throws `CancellationError` without running `work`.
    public func run<T: Sendable>(
        onWait: @escaping @Sendable (String) -> Void = { _ in },
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try await limiter.withSlot(onQueued: { onWait("Waiting for a free build slot (#\($0) in line)") }) {
            try await self.admit(onWait: onWait)
            do {
                let value = try await work()
                await self.release()
                return value
            } catch {
                await self.release()
                throw error
            }
        }
    }

    private func release() {
        executing -= 1
    }

    private func admit(onWait: @Sendable (String) -> Void) async throws {
        var told = false
        // Checking and counting happen without a suspension in between, so two waiting commands
        // can never both see the other as running.
        while executing > 0 && pressure() >= .warning {
            if !told {
                onWait("Waiting for memory: macOS reports memory pressure, so this starts when the running build finishes")
                told = true
            }
            try await Task.sleep(for: pollInterval)
        }
        executing += 1
    }
}
