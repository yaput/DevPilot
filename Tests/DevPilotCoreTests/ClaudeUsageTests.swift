import Foundation
import Synchronization
import Testing
@testable import DevPilotCore

struct ClaudeUsageTests {
    /// As Claude Code 2.1 streams it (from a real transcript).
    static let event = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793614800,"rateLimitType":"five_hour","overageStatus":"allowed","overageResetsAt":1796083200,"isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.39,"resetsAt":1793614800,"status":"allowed"},"seven_day":{"utilization":0.42,"resetsAt":1793894400,"status":"allowed_warning"}}},"uuid":"4c47dd94","session_id":"1b6f9392"}"#

    func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func readsBothWindowsFromARateLimitEvent() throws {
        let usage = try #require(ClaudeUsage(event: try decode(Self.event), at: Date(timeIntervalSince1970: 1_793_600_000)))
        #expect(usage.session == .init(utilization: 0.39, resetsAt: Date(timeIntervalSince1970: 1_793_614_800), status: "allowed"))
        #expect(usage.weekly?.utilization == 0.42)
        #expect(usage.weekly?.status == "allowed_warning")
        #expect(!usage.isUsingOverage)
    }

    @Test func otherEventsAreNotUsage() throws {
        #expect(ClaudeUsage(event: try decode(#"{"type":"assistant","message":{}}"#)) == nil)
        #expect(ClaudeUsage(event: try decode(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#)) == nil)
    }

    @Test func aNewerReadingKeepsWindowsItLacks() {
        let week = ClaudeUsage.Window(utilization: 0.5, resetsAt: Date(timeIntervalSince1970: 2_000), status: "allowed")
        let old = ClaudeUsage(session: nil, weekly: week, isUsingOverage: false, updatedAt: Date(timeIntervalSince1970: 1))
        let session = ClaudeUsage.Window(utilization: 0.1, resetsAt: Date(timeIntervalSince1970: 1_000), status: "allowed")
        let new = ClaudeUsage(session: session, weekly: nil, isUsingOverage: true, updatedAt: Date(timeIntervalSince1970: 2))
        let merged = old.updated(with: new)
        #expect(merged.session == session && merged.weekly == week && merged.isUsingOverage)
        #expect(merged.updatedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func aWindowPastItsResetCountsAsEmpty() {
        let window = ClaudeUsage.Window(utilization: 0.8, resetsAt: Date(timeIntervalSince1970: 1_000), status: "allowed")
        #expect(ClaudeUsage.current(window, now: Date(timeIntervalSince1970: 999)) == window)
        #expect(ClaudeUsage.current(window, now: Date(timeIntervalSince1970: 1_000)) == nil)
    }

    @Test func theLastReadingSurvivesARestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClaudeUsageStore(directory: directory)
        #expect(store.read() == nil)
        let usage = try #require(ClaudeUsage(event: try decode(Self.event)))
        store.write(usage)
        #expect(store.read() == usage)
    }

    @Test func fetchingUsesATinyToolFreeHaikuRequest() async throws {
        let fake = try FakeClaude(body: "printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\"}' '\(Self.event)'")
        defer { fake.remove() }
        let usage = try await ClaudeCLI.fetchUsage(executable: fake.executable)
        #expect(usage.session?.utilization == 0.39)
        let arguments = fake.recorded("args.txt").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(arguments.contains("haiku") && arguments.contains("--no-session-persistence"))
        #expect(arguments.firstIndex(of: "--tools").map { arguments.count > $0 + 1 && arguments[$0 + 1].isEmpty } == true)
        #expect(!fake.recorded("env.txt").contains("ANTHROPIC_API_KEY"))
    }

    @Test func noReadingIsAnError() async throws {
        let fake = try FakeClaude(body: "echo 'Not logged in' >&2; exit 1")
        defer { fake.remove() }
        await #expect(throws: ClaudeUsageError.self) { try await ClaudeCLI.fetchUsage(executable: fake.executable) }
    }

    @Test func runsReportUsageAsTheyStream() async throws {
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"ok","approach":"","affectedFiles":[],"implementationSteps":[],"testPlan":[],"risks":[],"openQuestions":[],"clarifyingQuestions":[],"outcome":"plan_ready","confidence":"high"}}"#
        let fake = try FakeClaude(body: "printf '%s\\n' '\(Self.event)' '\(result)'")
        defer { fake.remove() }
        let seen = Mutex<[ClaudeUsage]>([])
        let runner = ClaudeCodeRunner(
            executable: fake.executable, model: nil, investigationTimeout: .seconds(20), implementationTimeout: .seconds(20),
            onUsage: { usage in seen.withLock { $0.append(usage) } }
        )
        _ = try? await runner.investigate(InvestigationRequest(
            ticket: .sample(), workspace: .sample(worktree: fake.directory.path), previousPlan: nil, guidance: [],
            logURL: fake.directory.appending(path: "log.jsonl")
        )) { _ in }
        #expect(seen.withLock { $0.map(\.session?.utilization) } == [0.39])
    }
}
