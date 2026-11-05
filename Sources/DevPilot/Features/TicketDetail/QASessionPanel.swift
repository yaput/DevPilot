import AppKit
import DevPilotCore
import SwiftUI

/// "Run QA Session" against the ticket's local run, its live progress, and the bugs found, each
/// with DevPilot's replay verdict and evidence.
struct QASessionPanel: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    let workspace: TicketWorkspace
    @State private var showingProgress = false

    var body: some View {
        let session = model.qaSession?.ticketID == ticket.id ? model.qaSession : nil
        let past = session == nil ? model.qaSessions(ticketID: ticket.id).first : nil
        VStack(alignment: .leading, spacing: 8) {
            header(session)
            switch session?.phase {
            case .running(let messages)?:
                progress(messages)
            case .finished(let result)?:
                ResultView(result: result)
            case .failed(let message)?:
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).lineLimit(4).textSelection(.enabled)
            case nil:
                if let past { ResultView(result: past) }
            }
        }
    }

    private func header(_ session: QASessionState?) -> some View {
        let running = model.localRun?.ticketID == ticket.id && model.localRun?.phase == .running
        return HStack {
            Label("QA", systemImage: "ladybug").font(.headline)
            Spacer()
            if session?.isRunning == true {
                Button("Cancel", role: .destructive) { model.cancelQASession() }
            } else {
                if !running {
                    Text("Start the app with Run Locally to test it.").font(.caption).foregroundStyle(.secondary)
                } else if !model.qaTools.isInstalled {
                    Text("Install the QA browser tools in the repository's Local Run settings.").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    model.startQASession(ticketID: ticket.id, repositoryID: workspace.repositoryID)
                } label: {
                    Label("Run QA Session", systemImage: "play.circle")
                }
                .disabled(!running || !model.qaTools.isInstalled || model.qaSession?.isRunning == true)
            }
        }
    }

    private func progress(_ messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView().controlSize(.small)
                Text(messages.last ?? "Starting").font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(showingProgress ? "Hide Steps" : "Show Steps") { showingProgress.toggle() }.controlSize(.small)
            }
            if showingProgress {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
    }
}

private struct ResultView: View {
    let result: QASessionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let bugs = result.report.findings.count
                Text(bugs == 0 ? "No bugs found" : "\(bugs) bug\(bugs == 1 ? "" : "s"), \(result.confirmedCount) reproduced by replay")
                    .font(.callout.weight(.semibold))
                Text(result.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Report") { NSWorkspace.shared.open(URL(filePath: result.reportPath)) }.controlSize(.small)
                Button("Folder") { NSWorkspace.shared.open(URL(filePath: result.directory)) }.controlSize(.small)
            }
            Text(result.report.summary).font(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            ForEach(Array(zip(result.report.findings, result.replays).enumerated()), id: \.offset) { _, pair in
                FindingRow(finding: pair.0, replay: pair.1)
            }
        }
    }
}

private struct FindingRow: View {
    let finding: QAFinding
    let replay: QAReplayResult
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(QAReportRenderer.label(replay.status))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
                Text(finding.severity.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                Text(finding.title).font(.callout).lineLimit(expanded ? nil : 1)
                Spacer()
                if let video = replay.attempts.compactMap(\.video).first {
                    Button("Video") { NSWorkspace.shared.open(URL(filePath: video)) }.controlSize(.mini)
                }
                if let screenshot = replay.attempts.compactMap(\.screenshot).first {
                    Button("Screenshot") { NSWorkspace.shared.open(URL(filePath: screenshot)) }.controlSize(.mini)
                }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Expected: \(finding.expected)")
                    Text("Actual: \(finding.actual)")
                    ForEach(Array(finding.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                    }
                    Text("Replay: " + replay.attempts.map(\.message).joined(separator: " / ")).foregroundStyle(.secondary)
                }
                .font(.caption)
                .textSelection(.enabled)
                .padding(.leading, 8)
            }
        }
    }

    private var color: Color {
        switch replay.status {
        case .confirmed: .red
        case .flaky: .orange
        case .notReproduced: .secondary
        case .couldNotReplay: .yellow
        }
    }
}
