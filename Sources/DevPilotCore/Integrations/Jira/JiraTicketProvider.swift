import Foundation

/// Jira Cloud REST v3, authenticated with account email + API token (Basic auth). Read-only.
public struct JiraTicketProvider: TicketProvider {
    public let kind = TicketProviderKind.jira

    static let jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
    static let pageSize = 50
    /// Safety cap so a misconfigured filter cannot page forever.
    static let maxTickets = 500

    private let siteURL: URL
    private let acceptanceCriteriaField: String?
    private let authorization: String
    private let client: APIClient

    public init(siteURL: URL, email: String, apiToken: String, acceptanceCriteriaField: String?, http: any HTTPClient) {
        self.init(siteURL: siteURL, email: email, apiToken: apiToken, acceptanceCriteriaField: acceptanceCriteriaField, client: APIClient(http: http))
    }

    init(siteURL: URL, email: String, apiToken: String, acceptanceCriteriaField: String?, client: APIClient) {
        self.siteURL = siteURL
        self.acceptanceCriteriaField = acceptanceCriteriaField
        self.authorization = "Basic " + Data("\(email):\(apiToken)".utf8).base64EncodedString()
        self.client = client
    }

    private var source: String { siteURL.host() ?? siteURL.absoluteString }

    private var fields: [String] {
        ["summary", "description", "status", "assignee", "comment", "issuetype"] + [acceptanceCriteriaField].compactMap { $0 }
    }

    public func checkConnection() async throws -> String {
        let me = try await client.decode(JSONValue.self, from: request("rest/api/3/myself"))
        return "\(me["displayName"]?.string ?? "Unknown user") on \(source)"
    }

    public func assignedTickets() async throws -> [Ticket] {
        var tickets: [Ticket] = []
        var nextPageToken: String?
        repeat {
            let body = try JSONEncoder().encode(SearchRequest(
                jql: Self.jql, maxResults: Self.pageSize, fields: fields, nextPageToken: nextPageToken
            ))
            let page = try await client.decode(SearchResponse.self, from: request("rest/api/3/search/jql", method: "POST", body: body))
            let fetchedAt = Date()
            tickets += page.issues.map { makeTicket($0, fetchedAt: fetchedAt) }
            nextPageToken = page.isLast == true ? nil : page.nextPageToken
        } while nextPageToken != nil && tickets.count < Self.maxTickets
        return tickets
    }

    public func ticket(id: String) async throws -> Ticket {
        let key = externalID(from: id)
        guard key.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*-\d+/) != nil else { throw TicketProviderError.notFound(id) }
        var components = URLComponents(url: siteURL.appending(path: "rest/api/3/issue/\(key)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: fields.joined(separator: ","))]
        let issue = try await client.decode(Issue.self, from: .json(components.url!, headers: headers))
        return makeTicket(issue, fetchedAt: Date())
    }

    private var headers: [String: String] { ["Authorization": authorization] }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        .json(siteURL.appending(path: path), method: method, headers: headers, body: body)
    }

    private func makeTicket(_ issue: Issue, fetchedAt: Date) -> Ticket {
        let fields = issue.fields
        let description = ADFConverter.markdown(from: fields["description"])
        let comments = (fields["comment"]?["comments"]?.array ?? []).map { comment in
            TicketComment(
                author: comment["author"]?["displayName"]?.string ?? "Unknown",
                body: ADFConverter.markdown(from: comment["body"]),
                createdAt: APIDate.parse(comment["created"]?.string) ?? fetchedAt
            )
        }
        var criteria = acceptanceCriteriaField.map { Self.criteria(from: fields[$0]) } ?? []
        if criteria.isEmpty {
            criteria = AcceptanceCriteriaExtractor.extract(fromMarkdown: description)
        }
        return Ticket(
            provider: .jira,
            source: source,
            externalID: issue.key,
            title: fields["summary"]?.string ?? "(no summary)",
            description: description,
            status: fields["status"]?["name"]?.string ?? "Unknown",
            assignee: fields["assignee"]?["displayName"]?.string,
            url: siteURL.appending(path: "browse/\(issue.key)"),
            comments: comments,
            acceptanceCriteria: criteria,
            fetchedAt: fetchedAt,
            type: TicketType(providerName: fields["issuetype"]?["name"]?.string ?? "")
        )
    }

    /// A criteria custom field may be plain text, rich text (ADF) or a multi-select.
    static func criteria(from value: JSONValue?) -> [String] {
        switch value {
        case .string(let text)?:
            return AcceptanceCriteriaExtractor.items(fromText: text)
        case .array(let items)?:
            return items.compactMap { $0.string ?? $0["value"]?.string }
        case .object?:
            return AcceptanceCriteriaExtractor.items(fromText: ADFConverter.markdown(from: value))
        default:
            return []
        }
    }

    private struct SearchRequest: Encodable {
        let jql: String
        let maxResults: Int
        let fields: [String]
        let nextPageToken: String?
    }

    private struct SearchResponse: Decodable {
        let issues: [Issue]
        let nextPageToken: String?
        let isLast: Bool?
    }

    private struct Issue: Decodable {
        let key: String
        let fields: [String: JSONValue]
    }
}
