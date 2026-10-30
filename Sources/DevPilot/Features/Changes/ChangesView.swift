import AppKit
import DevPilotCore
import SwiftUI

/// Window showing everything that differs from the ticket's base commit, file by file.
struct ChangesView: View {
    @Environment(AppModel.self) private var model
    let ticketID: String

    @State private var files: [FileDiff] = []
    @State private var workspace: TicketWorkspace?
    @State private var selection: String?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        NavigationSplitView {
            List(files, selection: $selection) { file in
                FileRow(file: file)
            }
            .overlay {
                if files.isEmpty && !isLoading {
                    ContentUnavailableView(error == nil ? "No changes" : "Could not load changes", systemImage: "doc.text.magnifyingglass",
                                           description: Text(error ?? emptyExplanation))
                }
            }
            .safeAreaInset(edge: .bottom) { summary }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let file = files.first(where: { $0.id == selection }) {
                DiffView(file: file)
            } else {
                ContentUnavailableView("Select a file", systemImage: "sidebar.left")
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                if let editor = model.preferredEditor, let workspace {
                    Button {
                        if let selection {
                            editor.open(URL(filePath: workspace.worktreePath).appending(path: selection))
                        }
                    } label: {
                        Label("Open File in \(editor.name)", systemImage: "doc.badge.arrow.up")
                    }
                    .disabled(selection == nil || files.first { $0.id == selection }?.change == .deleted)
                    .help("Open the selected file in \(editor.name)")
                    OpenWorktreeMenu(workspace: workspace)
                }
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(isLoading)
            }
        }
        .task { await load() }
    }

    private var emptyExplanation: String {
        switch model.state(of: ticketID) {
        case .selected, .investigating, .needsClarification, .planReady, .awaitingPlanApproval, .needsRevision, .approved:
            "Nothing has been implemented yet: investigation only reads the code. Approve the plan and click Implement."
        default:
            "The worktree matches its base commit."
        }
    }

    private var title: String {
        model.tickets.first { $0.id == ticketID }.map { "Changes: \($0.externalID) \($0.title)" } ?? "Changes"
    }

    private var summary: some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        return VStack(alignment: .leading, spacing: 2) {
            if isLoading { ProgressView().controlSize(.small) }
            Text("\(files.count) file\(files.count == 1 ? "" : "s")  ")
                + Text("+\(additions)").foregroundStyle(.green)
                + Text(" −\(deletions)").foregroundStyle(.red)
            if let workspace {
                Text("vs \(workspace.baseBranch) @ \(workspace.baseCommit.prefix(8)) · \(workspace.branch)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (workspace, files) = try await model.loadChanges(ticketID)
            self.workspace = workspace
            self.files = files
            error = nil
            if selection == nil || !files.contains(where: { $0.id == selection }) {
                selection = files.first?.id
            }
        } catch {
            self.error = error.localizedDescription
            files = []
        }
    }
}

private struct FileRow: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 6) {
            Text(badge.letter)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(badge.color)
                .frame(width: 14)
                .help(file.change.rawValue)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(filePath: file.path).lastPathComponent).lineLimit(1)
                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if file.isBinary {
                Text("binary").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("+\(file.additions)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                Text("−\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red)
            }
        }
    }

    private var badge: (letter: String, color: Color) {
        switch file.change {
        case .added, .untracked: ("A", .green)
        case .deleted: ("D", .red)
        case .renamed: ("R", .blue)
        case .modified: ("M", .orange)
        case .other: ("?", .secondary)
        }
    }
}

private struct DiffView: View {
    let file: FileDiff

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(10)
            .background(.bar)
            Divider()
            if file.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.zipper")
            } else if file.lines.isEmpty {
                ContentUnavailableView("No content changes", systemImage: "doc", description: Text(file.change == .renamed ? "Renamed only." : ""))
            } else {
                GeometryReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line).frame(minWidth: proxy.size.width, alignment: .leading)
                            }
                            if file.isTruncated {
                                Text("Diff truncated after \(UnifiedDiffParser.maxLinesPerFile) lines. Open the file in your editor for the rest.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: FileDiff.Line

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(line.kind == .hunkHeader || line.kind == .note ? .secondary : .primary)
                .padding(.trailing, 16)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: .green.opacity(0.14)
        case .deletion: .red.opacity(0.14)
        case .hunkHeader: .blue.opacity(0.08)
        default: .clear
        }
    }
}

/// "Open in IntelliJ IDEA" for the worktree, with each sub-project of a monorepo as an option.
struct OpenWorktreeMenu: View {
    @Environment(AppModel.self) private var model
    let workspace: TicketWorkspace

    var body: some View {
        if let editor = model.preferredEditor {
            let root = URL(filePath: workspace.worktreePath, directoryHint: .isDirectory)
            let projects = CommandPresets.projectDirectories(in: root).filter { !$0.isEmpty }
            if projects.isEmpty {
                Button { editor.open(root) } label: { Label("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right") }
            } else {
                Menu {
                    Button("Whole repository") { editor.open(root) }
                    Divider()
                    ForEach(projects, id: \.self) { project in
                        Button(project) { editor.open(root.appending(path: project, directoryHint: .isDirectory)) }
                    }
                } label: {
                    Label("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
    }
}
