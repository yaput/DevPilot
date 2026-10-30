import Foundation
import Testing
@testable import DevPilotCore

struct ShortcutTicketProviderTests {
    let api = URL(string: "https://api.app.shortcut.com")!

    func provider(_ http: MockHTTPClient) -> ShortcutTicketProvider {
        ShortcutTicketProvider(apiURL: api, apiToken: "sc-token", client: APIClient(http: http, sleep: SleepRecorder().sleep))
    }

    func workspace() -> MockHTTPClient {
        MockHTTPClient { request in
            switch request.url?.path() {
            case "/api/v3/member": .fixture("shortcut-member.json")
            case "/api/v3/members": .fixture("shortcut-members.json")
            case "/api/v3/workflows": .fixture("shortcut-workflows.json")
            case "/api/v3/search/stories":
                request.queryItems["next"] == "abc123" ? .fixture("shortcut-search-page2.json") : .fixture("shortcut-search-page1.json")
            case "/api/v3/stories/4211": .fixture("shortcut-story-4211.json")
            case "/api/v3/stories/4230": .fixture("shortcut-story-4230.json")
            default: .status(404)
            }
        }
    }

    @Test func returnsOnlyOpenStoriesAcrossPages() async throws {
        let http = workspace()
        let tickets = try await provider(http).assignedTickets()

        // 4300 is completed in search results (never fetched); 4230 is in a "done" workflow state.
        #expect(tickets.map(\.externalID) == ["4211"])
        let fetched = http.requests.compactMap { $0.url?.path() }.filter { $0.hasPrefix("/api/v3/stories/") }
        #expect(Set(fetched) == ["/api/v3/stories/4211", "/api/v3/stories/4230"])
    }

    @Test func searchesStoriesOwnedByCurrentMember() async throws {
        let http = workspace()
        _ = try await provider(http).assignedTickets()

        let search = try #require(http.requests.first { $0.url?.path() == "/api/v3/search/stories" })
        #expect(search.queryItems["query"] == "owner:jane !is:done !is:archived")
        #expect(search.queryItems["page_size"] == "25")
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Shortcut-Token") == "sc-token" })
    }

    @Test func normalizesStoryFields() async throws {
        let ticket = try #require(try await provider(workspace()).assignedTickets().first)

        #expect(ticket.id == "shortcut:acme/4211")
        #expect(ticket.source == "acme")
        #expect(ticket.title == "Add retry with backoff to webhook delivery")
        #expect(ticket.status == "Ready for Development")
        #expect(ticket.assignee == "Jane Doe")
        #expect(ticket.url.absoluteString == "https://app.shortcut.com/acme/story/4211")
        #expect(ticket.acceptanceCriteria == ["Retries on 5xx and timeouts, not on 4xx", "Backoff capped at 10 minutes total"])
        #expect(ticket.description.hasSuffix("## Tasks\n- [ ] Add dead-letter table"))
        #expect(ticket.comments.count == 1)
        #expect(ticket.comments.first?.author == "Product Manager")
        #expect(ticket.comments.first?.createdAt == Date(timeIntervalSince1970: 1_793_150_130))
    }

    @Test func checkConnectionReportsMemberAndWorkspace() async throws {
        #expect(try await provider(workspace()).checkConnection() == "Jane Doe (@jane) in workspace acme")
    }

    @Test func refusesPaginationLinksToOtherHosts() async throws {
        let http = MockHTTPClient { request in
            switch request.url?.path() {
            case "/api/v3/member": .fixture("shortcut-member.json")
            case "/api/v3/members": .fixture("shortcut-members.json")
            case "/api/v3/workflows": .fixture("shortcut-workflows.json")
            default: .status(200, #"{"data": [], "next": "https://evil.example.com/api/v3/search/stories?next=x"}"#)
            }
        }
        await #expect(throws: TicketProviderError.self) {
            _ = try await provider(http).assignedTickets()
        }
        #expect(!http.requests.contains { $0.url?.host() == "evil.example.com" })
    }

    @Test func singleStoryByFullID() async throws {
        let ticket = try await provider(workspace()).ticket(id: "shortcut:acme/4211")
        #expect(ticket.externalID == "4211")
    }

    @Test func rejectedTokenIsUnauthorized() async throws {
        let http = MockHTTPClient { _ in .status(401, #"{"message":"Unauthorized"}"#) }
        await #expect(throws: TicketProviderError.unauthorized) {
            _ = try await provider(http).checkConnection()
        }
    }
}
