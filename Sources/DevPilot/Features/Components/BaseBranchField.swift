import DevPilotCore
import SwiftUI

/// A base-branch text field with a menu of the repository's branches and how recently each
/// was committed to, so a stale branch is obvious before a worktree is created from it.
struct BaseBranchField: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var branch: String
    let repositoryPath: String

    @State private var branches: [GitWorktreeManager.Branch] = []

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $branch, prompt: Text("main"))
                    .labelsHidden()
                    .font(.callout.monospaced())
                Menu {
                    section("Local", branches.filter { !$0.isRemote })
                    section("Remote (as of last fetch)", branches.filter(\.isRemote))
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose a branch")
                .disabled(branches.isEmpty)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let selected = branches.first(where: { $0.name == branch }) {
                Text("last commit \(selected.lastCommitDate.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(isStale(selected) ? .orange : .secondary)
                    .offset(y: 14)
            }
        }
        .padding(.bottom, branches.contains { $0.name == branch } ? 12 : 0)
        .task(id: repositoryPath) {
            branches = await model.branches(inRepositoryAt: repositoryPath)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [GitWorktreeManager.Branch]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items.prefix(25)) { item in
                    Button("\(item.name)  ·  \(item.lastCommitDate.formatted(.relative(presentation: .named)))") {
                        branch = item.name
                    }
                }
            }
        }
    }

    /// Older than 30 days: worth a second look before branching from it.
    private func isStale(_ branch: GitWorktreeManager.Branch) -> Bool {
        branch.lastCommitDate < Date().addingTimeInterval(-30 * 86_400)
    }
}
