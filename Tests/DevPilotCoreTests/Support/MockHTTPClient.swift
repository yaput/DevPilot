import Foundation
import Synchronization
@testable import DevPilotCore

/// Routes requests to canned responses and records every request it sees.
final class MockHTTPClient: HTTPClient {
    struct Response {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]

        static func fixture(_ name: String) -> Response {
            Response(body: Fixture.data(name))
        }

        static func status(_ status: Int, _ body: String = "", headers: [String: String] = [:]) -> Response {
            Response(status: status, body: Data(body.utf8), headers: headers)
        }
    }

    private let handler: @Sendable (URLRequest) throws -> Response
    private let log = Mutex<[URLRequest]>([])

    init(_ handler: @escaping @Sendable (URLRequest) throws -> Response) {
        self.handler = handler
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        let response = try handler(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }
}

/// Sequenced responses: returns them in order, repeating the last one.
final class ResponseSequence: Sendable {
    private let responses: Mutex<[MockHTTPClient.Response]>

    init(_ responses: [MockHTTPClient.Response]) {
        self.responses = Mutex(responses)
    }

    func next() -> MockHTTPClient.Response {
        responses.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

final class SleepRecorder: Sendable {
    private let durations = Mutex<[Duration]>([])
    var recorded: [Duration] { durations.withLock { $0 } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in durations.withLock { $0.append(duration) } }
    }
}

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static func json(_ name: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: data(name))
    }
}

extension URLRequest {
    var queryItems: [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    var jsonBody: JSONValue? {
        httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}
