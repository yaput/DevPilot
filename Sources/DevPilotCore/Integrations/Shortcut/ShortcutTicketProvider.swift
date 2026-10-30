import Foundation

/// Shortcut REST v3, authenticated with an API token. The token determines the workspace. Read-only.
public struct ShortcutTicketProvider: TicketProvider {
    public let kind = TicketProviderKind.shortcut

    static let pageSize = 25
    static let maxTickets = 500
    static let detailConcurrency = 4

    private let apiURL: URL
    private let token: String
    private let client: APIClient

    public init(apiURL: URL, apiToken: String, http: any HTTPClient) {
        self.init(apiURL: apiURL, apiToken: apiToken, client: APIClient(http: http))
    }

    init(apiURL: URL, apiToken: String, client: APIClient) {
        self.apiURL = apiURL
        self.token = apiToken
        self.client = client
    }

    public func checkConnection() async throws -> String {
        let member = try await currentMember()
        return "\(member.name ?? member.mentionName) (@\(member.mentionName)) in workspace \(member.workspace)"
    }

    public func assignedTickets() async throws -> [Ticket] {
        let member = try await currentMember()
        async let states = workflowStates()
        async let names = memberNames()
        // `!is:done` keeps the search small; the state type is re-checked below in case the query is too loose.
        let candidates = try await searchStories(query: "owner:\(member.mentionName) !is:done !is:archived")
            .filter { $0.archived != true && $0.completed != true }
        let stories = try await concurrentMap(candidates.map(\.id), limit: Self.detailConcurrency) { id in
            try await story(id)
        }
        let (stateByID, nameByID) = try await (states, names)
        let fetchedAt = Date()
        return stories
            .filter { $0.archived != true && stateByID[$0.workflowStateID]?.type != "done" }
            .map { makeTicket($0, workspace: member.workspace, states: stateByID, names: nameByID, fetchedAt: fetchedAt) }
    }

    public func ticket(id: String) async throws -> Ticket {
        guard let storyID = Int(externalID(from: id)) else { throw TicketProviderError.notFound(id) }
        async let member = currentMember()
        async let states = workflowStates()
        async let names = memberNames()
        let story = try await story(storyID)
        return try await makeTicket(story, workspace: member.workspace, states: states, names: names, fetchedAt: Date())
    }

    // MARK: - Requests

    private func request(_ url: URL) -> URLRequest {
        .json(url, headers: ["Shortcut-Token": token])
    }

    private func endpoint(_ path: String) -> URL {
        apiURL.appending(path: "api/v3/\(path)")
    }

    private func currentMember() async throws -> Member {
        let json = try await client.decode(JSONValue.self, from: request(endpoint("member")))
        guard let mention = json["mention_name"]?.string ?? json["profile"]?["mention_name"]?.string else {
            throw TicketProviderError.invalidResponse("Shortcut /member has no mention_name")
        }
        return Member(
            mentionName: mention,
            name: json["name"]?.string ?? json["profile"]?["name"]?.string,
            workspace: json["workspace2"]?["url_slug"]?.string ?? "workspace"
        )
    }

    private func workflowStates() async throws -> [Int: WorkflowStateInfo] {
        let workflows = try await client.decode([Workflow].self, from: request(endpoint("workflows")))
        return Dictionary(workflows.flatMap(\.states).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func memberNames() async throws -> [String: String] {
        let members = try await client.decode([JSONValue].self, from: request(endpoint("members")))
        var names: [String: String] = [:]
        for member in members {
            if let id = member["id"]?.string, let name = member["profile"]?["name"]?.string {
                names[id] = name
            }
        }
        return names
    }

    private func searchStories(query: String) async throws -> [StorySlim] {
        var components = URLComponents(url: endpoint("search/stories"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page_size", value: String(Self.pageSize)),
            URLQueryItem(name: "detail", value: "slim"),
        ]
        var next = components.url
        var results: [StorySlim] = []
        while let url = next, results.count < Self.maxTickets {
            let page = try await client.decode(SearchPage.self, from: request(url))
            results += page.data
            next = try page.next.map(resolveNext)
        }
        return results
    }

    /// `next` is a server-relative path. Refuse anything that would send the token to another host.
    private func resolveNext(_ next: String) throws -> URL {
        guard let url = URL(string: next, relativeTo: apiURL)?.absoluteURL, url.host() == apiURL.host() else {
            throw TicketProviderError.invalidResponse("Unexpected pagination link: \(next)")
        }
        return url
    }

    private func story(_ id: Int) async throws -> Story {
        try await client.decode(Story.self, from: request(endpoint("stories/\(id)")))
    }

    // MARK: - Mapping

    private func makeTicket(
        _ story: Story,
        workspace: String,
        states: [Int: WorkflowStateInfo],
        names: [String: String],
        fetchedAt: Date
    ) -> Ticket {
        var description = story.description ?? ""
        let tasks = story.tasks ?? []
        if !tasks.isEmpty {
            // Keep tasks as context; they are often implementation steps rather than criteria.
            let checklist = tasks.map { "- [\($0.complete ? "x" : " ")] \($0.description)" }.joined(separator: "\n")
            description += (description.isEmpty ? "" : "\n\n") + "## Tasks\n" + checklist
        }
        let comments = (story.comments ?? [])
            .filter { $0.deleted != true }
            .compactMap { comment -> TicketComment? in
                guard let text = comment.text, !text.isEmpty else { return nil }
                return TicketComment(
                    author: comment.authorID.flatMap { names[$0] } ?? "Unknown",
                    body: text,
                    createdAt: APIDate.parse(comment.createdAt) ?? fetchedAt
                )
            }
        let owners = (story.ownerIDs ?? []).compactMap { names[$0] }
        return Ticket(
            provider: .shortcut,
            source: workspace,
            externalID: String(story.id),
            title: story.name,
            description: description,
            status: states[story.workflowStateID]?.name ?? "Unknown",
            assignee: owners.isEmpty ? nil : owners.joined(separator: ", "),
            url: URL(string: story.appURL) ?? URL(string: "https://app.shortcut.com/\(workspace)/story/\(story.id)")!,
            comments: comments,
            acceptanceCriteria: AcceptanceCriteriaExtractor.extract(fromMarkdown: story.description ?? ""),
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Payloads

    private struct Member {
        let mentionName: String
        let name: String?
        let workspace: String
    }

    private struct Workflow: Decodable {
        let states: [WorkflowStateInfo]
    }

    private struct WorkflowStateInfo: Decodable {
        let id: Int
        let name: String
        /// `unstarted`, `started` or `done`.
        let type: String
    }

    private struct SearchPage: Decodable {
        let data: [StorySlim]
        let next: String?
    }

    private struct StorySlim: Decodable {
        let id: Int
        let archived: Bool?
        let completed: Bool?
    }

    private struct Story: Decodable {
        let id: Int
        let name: String
        let description: String?
        let appURL: String
        let workflowStateID: Int
        let ownerIDs: [String]?
        let archived: Bool?
        let comments: [Comment]?
        let tasks: [Task]?

        enum CodingKeys: String, CodingKey {
            case id, name, description, archived, comments, tasks
            case appURL = "app_url"
            case workflowStateID = "workflow_state_id"
            case ownerIDs = "owner_ids"
        }
    }

    private struct Comment: Decodable {
        let authorID: String?
        let text: String?
        let createdAt: String?
        let deleted: Bool?

        enum CodingKeys: String, CodingKey {
            case text, deleted
            case authorID = "author_id"
            case createdAt = "created_at"
        }
    }

    private struct Task: Decodable {
        let description: String
        let complete: Bool
    }
}
