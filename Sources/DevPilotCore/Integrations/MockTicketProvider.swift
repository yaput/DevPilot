import Foundation

/// Fixture-backed provider behind the "Use sample data" setting, and in tests.
public struct MockTicketProvider: TicketProvider {
    public static let source = "sample"

    public let kind: TicketProviderKind
    private let tickets: [Ticket]

    public init(kind: TicketProviderKind, tickets: [Ticket]) {
        self.kind = kind
        self.tickets = tickets
    }

    public func assignedTickets() async throws -> [Ticket] {
        tickets
    }

    public func ticket(id: String) async throws -> Ticket {
        guard let ticket = tickets.first(where: { $0.externalID == externalID(from: id) }) else {
            throw TicketProviderError.notFound(id)
        }
        return ticket
    }

    public func checkConnection() async throws -> String {
        "Sample data (\(tickets.count) tickets)"
    }
}

extension MockTicketProvider {
    public static func sample(_ kind: TicketProviderKind, now: Date = Date()) -> MockTicketProvider {
        let comment = { (author: String, body: String, daysAgo: Double) in
            TicketComment(author: author, body: body, createdAt: now.addingTimeInterval(-daysAgo * 86_400))
        }
        switch kind {
        case .shortcut:
            let story = { (id: String, title: String, description: String, status: String, comments: [TicketComment], criteria: [String]) in
                Ticket(
                    provider: .shortcut, source: Self.source, externalID: id, title: title, description: description, status: status,
                    assignee: "me", url: URL(string: "https://app.shortcut.com/example/story/\(id)")!,
                    comments: comments, acceptanceCriteria: criteria, fetchedAt: now
                )
            }
            return MockTicketProvider(kind: .shortcut, tickets: [
                story(
                    "4211", "Add retry with backoff to webhook delivery",
                    "Webhook deliveries to merchant endpoints fail permanently on the first 5xx. Retry up to 5 times with exponential backoff and jitter, then move the event to the dead-letter table.",
                    "Ready for Development",
                    [comment("PM", "Keep the max total delay under 10 minutes.", 2)],
                    ["Retries on 5xx and timeouts, not on 4xx", "Backoff capped at 10 minutes total", "Dead-lettered events are visible in admin"]
                ),
                story(
                    "4230", "Fix timezone bug in daily digest email",
                    "Users in UTC+9 receive the digest a day late.",
                    "In Development",
                    [],
                    ["Digest is sent at 08:00 in the user's local timezone"]
                ),
                story(
                    "4247", "Improve search",
                    "Search should be better.",
                    "Unstarted",
                    [comment("Support", "Customers complain a lot.", 1)],
                    []
                ),
            ])
        case .jira:
            let issue = { (key: String, title: String, description: String, status: String, comments: [TicketComment], criteria: [String]) in
                Ticket(
                    provider: .jira, source: Self.source, externalID: key, title: title, description: description, status: status,
                    assignee: "me", url: URL(string: "https://example.atlassian.net/browse/\(key)")!,
                    comments: comments, acceptanceCriteria: criteria, fetchedAt: now
                )
            }
            return MockTicketProvider(kind: .jira, tickets: [
                issue(
                    "PLAT-182", "Rate-limit public API by API key",
                    "Apply a token-bucket limit of 100 req/min per API key on /v1/*. Return 429 with Retry-After.",
                    "To Do",
                    [comment("Tech Lead", "Use the existing Redis cluster; no new infra.", 3)],
                    ["429 with Retry-After header when exceeded", "Limits configurable per plan", "Metrics emitted for throttled requests"]
                ),
                issue(
                    "PLAT-190", "Upgrade ORM to next major version",
                    "The current ORM version reaches end of life this quarter. Upgrade and fix deprecations.",
                    "In Progress",
                    [],
                    ["All tests pass", "No deprecation warnings in build output"]
                ),
                issue(
                    "MOB-77", "Crash when opening order details offline",
                    "Steps: enable airplane mode, open Orders, tap any order. App crashes with a null dereference in OrderDetailViewModel.",
                    "Selected for Development",
                    [comment("QA", "Reproducible on iOS 18 and Android 15.", 1)],
                    ["No crash offline", "Cached order details are shown when available"]
                ),
            ])
        }
    }
}
