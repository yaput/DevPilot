import Foundation
import Testing
@testable import DevPilotCore

struct JiraTicketProviderTests {
    let site = URL(string: "https://acme.atlassian.net")!

    func provider(_ http: MockHTTPClient, field: String? = "customfield_10035", sleeps: SleepRecorder = SleepRecorder()) -> JiraTicketProvider {
        JiraTicketProvider(
            siteURL: site, email: "jane@example.com", apiToken: "secret-token", acceptanceCriteriaField: field,
            client: APIClient(http: http, sleep: sleeps.sleep)
        )
    }

    func pagedSearch() -> MockHTTPClient {
        MockHTTPClient { request in
            guard request.url?.path() == "/rest/api/3/search/jql" else { return .status(404) }
            return request.jsonBody?["nextPageToken"]?.string == "page-2-token"
                ? .fixture("jira-search-page2.json")
                : .fixture("jira-search-page1.json")
        }
    }

    @Test func followsNextPageTokenAcrossPages() async throws {
        let http = pagedSearch()
        let tickets = try await provider(http).assignedTickets()

        #expect(tickets.map(\.externalID) == ["PLAT-182", "MOB-77"])
        #expect(http.requests.count == 2)
        #expect(http.requests[0].jsonBody?["nextPageToken"] == nil)
        #expect(http.requests[1].jsonBody?["nextPageToken"]?.string == "page-2-token")
    }

    @Test func sendsReadOnlyAssignedSearchWithBasicAuth() async throws {
        let http = pagedSearch()
        _ = try await provider(http).assignedTickets()

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("jane@example.com:secret-token".utf8).base64EncodedString())
        let body = try #require(request.jsonBody)
        #expect(body["jql"]?.string?.contains("assignee = currentUser()") == true)
        #expect(body["fields"]?.array?.contains(.string("customfield_10035")) == true)
    }

    @Test func normalizesIssueFields() async throws {
        let tickets = try await provider(pagedSearch()).assignedTickets()
        let ticket = try #require(tickets.first)

        #expect(ticket.id == "jira:acme.atlassian.net/PLAT-182")
        #expect(ticket.source == "acme.atlassian.net")
        #expect(ticket.status == "To Do")
        #expect(ticket.assignee == "Jane Doe")
        #expect(ticket.url.absoluteString == "https://acme.atlassian.net/browse/PLAT-182")
        #expect(ticket.description.contains("Apply a **token-bucket** limit on `/v1/*`. See [RFC 6585](https://www.rfc-editor.org/rfc/rfc6585)."))
        #expect(ticket.description.contains("@Tech Lead prefers Redis."))
        #expect(ticket.comments.map(\.body) == ["Use the existing Redis cluster."])
        #expect(ticket.comments.first?.author == "Tech Lead")
        #expect(ticket.comments.first?.createdAt == Date(timeIntervalSince1970: 1_793_063_730.123))
    }

    @Test func criteriaComeFromDescriptionWhenFieldIsEmpty() async throws {
        let tickets = try await provider(pagedSearch()).assignedTickets()
        #expect(tickets[0].acceptanceCriteria == ["429 with Retry-After when exceeded", "Limits configurable per plan"])
    }

    @Test func criteriaComeFromCustomFieldWhenPresent() async throws {
        let tickets = try await provider(pagedSearch()).assignedTickets()
        #expect(tickets[1].description == "")
        #expect(tickets[1].acceptanceCriteria == ["No crash offline", "Cached details shown"])
    }

    @Test func criteriaFieldShapes() {
        #expect(JiraTicketProvider.criteria(from: .string("- one\n- two\n")) == ["one", "two"])
        #expect(JiraTicketProvider.criteria(from: .array([.object(["value": .string("A")]), .string("B")])) == ["A", "B"])
        #expect(JiraTicketProvider.criteria(from: .null).isEmpty)
    }

    @Test func checkConnectionReportsUserAndSite() async throws {
        let http = MockHTTPClient { _ in .fixture("jira-myself.json") }
        #expect(try await provider(http).checkConnection() == "Jane Doe on acme.atlassian.net")
        #expect(http.requests.first?.url?.path() == "/rest/api/3/myself")
    }

    @Test func rejectedTokenIsUnauthorizedWithoutRetry() async throws {
        let http = MockHTTPClient { _ in .status(401, #"{"errorMessages":["Unauthorized"]}"#) }
        await #expect(throws: TicketProviderError.unauthorized) {
            _ = try await provider(http).assignedTickets()
        }
        #expect(http.requests.count == 1)
    }

    @Test func honorsRetryAfterOn429() async throws {
        let responses = ResponseSequence([
            .status(429, headers: ["Retry-After": "7"]),
            .fixture("jira-search-page2.json"),
        ])
        let http = MockHTTPClient { _ in responses.next() }
        let sleeps = SleepRecorder()

        let tickets = try await provider(http, sleeps: sleeps).assignedTickets()

        #expect(tickets.count == 1)
        #expect(sleeps.recorded == [.seconds(7)])
    }

    @Test func gives5xxUpAfterMaxAttempts() async throws {
        let http = MockHTTPClient { _ in .status(503, #"{"errorMessages":["Service unavailable"]}"#) }
        let sleeps = SleepRecorder()

        await #expect(throws: TicketProviderError.http(status: 503, message: "Service unavailable")) {
            _ = try await provider(http, sleeps: sleeps).assignedTickets()
        }
        #expect(http.requests.count == RetryPolicy().maxAttempts)
        #expect(sleeps.recorded.count == RetryPolicy().maxAttempts - 1)
    }

    @Test func excessiveRetryAfterFailsFast() async throws {
        let http = MockHTTPClient { _ in .status(429, headers: ["Retry-After": "3600"]) }
        await #expect(throws: TicketProviderError.rateLimited) {
            _ = try await provider(http).assignedTickets()
        }
        #expect(http.requests.count == 1)
    }

    @Test func singleTicketRejectsMalformedKeys() async throws {
        let http = MockHTTPClient { _ in .status(500) }
        await #expect(throws: TicketProviderError.notFound("../../admin")) {
            _ = try await provider(http).ticket(id: "../../admin")
        }
        #expect(http.requests.isEmpty)
    }
}
