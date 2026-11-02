import AppKit
import DevPilotCore
import SwiftUI

/// "Run Locally" on a ticket with a worktree: start, watch, open in the browser, stop.
struct LocalRunPanel: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    let workspace: TicketWorkspace

    var body: some View {
        let repository = model.workspaceSettings.repository(id: workspace.repositoryID)
        if let run = model.localRun, run.ticketID == ticket.id {
            runView(run, repository: repository)
        } else if let other = model.localRun, !isFinished(other) {
            HStack {
                Label("The app is running locally for another ticket.", systemImage: "play.circle")
                    .foregroundStyle(.secondary)
                Button("Stop It") { Task { await model.stopLocalRun() } }
            }
            .font(.callout)
        } else if repository?.localRun.isConfigured == true {
            HStack {
                Button {
                    model.startLocalRun(ticketID: ticket.id, workspace: workspace)
                } label: {
                    Label("Run Locally", systemImage: "play.circle")
                }
                Text("Starts the app from this worktree on its own ports and a copy of the database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Text("Run Locally needs this repository's services set up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Configure…") }.controlSize(.small)
            }
        }
    }

    private func runView(_ run: LocalRunStatus, repository: RepositoryConfig?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch run.phase {
                case .starting(let step):
                    ProgressView().controlSize(.small)
                    Text(step).lineLimit(1).truncationMode(.middle)
                case .running:
                    Label("Running locally", systemImage: "play.circle.fill").foregroundStyle(.green)
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text("Stopping…")
                case .stopped:
                    Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                Spacer()
                if run.phase == .running, let url = run.appURL.flatMap(URL.init(string:)) {
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                }
                if isFinished(run) {
                    Button("Dismiss") { model.dismissLocalRunResult() }
                } else {
                    Button("Stop", role: .destructive) { Task { await model.stopLocalRun() } }
                }
            }
            ForEach(run.services) { service in
                HStack(spacing: 6) {
                    icon(service.state)
                    Text(service.name).font(.callout.monospaced())
                    if let port = service.port {
                        Text(":\(port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Log") { NSWorkspace.shared.open(URL(filePath: service.logPath)) }
                        .controlSize(.mini)
                        .disabled(!FileManager.default.fileExists(atPath: service.logPath))
                }
            }
            ForEach(run.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if run.phase == .running, let repository, repository.qa.login.isEnabled {
                signInRow(repository)
            }
            if let database = run.database {
                Text("Database: \(database) (a copy, dropped when stopped)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Signs in the way a QA session will, and shows what the saved session opens.
    @ViewBuilder
    private func signInRow(_ repository: RepositoryConfig) -> some View {
        HStack(spacing: 6) {
            switch model.qaSignIn {
            case .signingIn?:
                ProgressView().controlSize(.mini)
                Text("Signing in…").font(.callout)
            case .signedIn(_, let result)?:
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                Text("Signed in; the saved session opens \(URL(string: result.finalURL)?.path() ?? result.finalURL)")
                    .font(.callout)
                    .lineLimit(1)
                Button("Screenshot") { NSWorkspace.shared.open(URL(filePath: result.screenshotPath)) }.controlSize(.mini)
            case .failed(_, let message, let screenshot)?:
                Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(.red)
                Text(message).font(.callout).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                if let screenshot {
                    Button("Screenshot") { NSWorkspace.shared.open(URL(filePath: screenshot)) }.controlSize(.mini)
                }
            case nil:
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text("QA sign-in not tested yet").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Test Sign-in") { Task { await model.testQASignIn(repositoryID: repository.id) } }
                .controlSize(.small)
                .disabled(model.qaSignIn?.isSigningIn == true)
        }
    }

    @ViewBuilder
    private func icon(_ state: LocalRunStatus.Service.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .starting: ProgressView().controlSize(.mini)
        case .ready, .running: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private func isFinished(_ run: LocalRunStatus) -> Bool {
        switch run.phase {
        case .failed, .stopped: true
        default: false
        }
    }
}
