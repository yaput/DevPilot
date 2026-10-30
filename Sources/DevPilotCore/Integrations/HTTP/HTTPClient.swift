import Foundation

/// Minimal transport seam so adapters can be tested against recorded fixtures.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        // Ephemeral: no cookies, cache or credentials persisted to disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TicketProviderError.invalidResponse("Non-HTTP response from \(request.url?.host() ?? "server")")
        }
        return (data, http)
    }
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// A Retry-After longer than this fails fast instead of blocking the sync.
    public var maxRetryAfter: Duration

    public init(maxAttempts: Int = 4, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(20), maxRetryAfter: Duration = .seconds(60)) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
    }

    func backoff(afterAttempt attempt: Int) -> Duration {
        let exponential = baseDelay * (1 << min(attempt - 1, 16))
        return min(exponential, maxDelay) * Double.random(in: 0.8...1.2)
    }
}

/// Sends requests with retries for 429/5xx/transient network errors and maps failures to
/// `TicketProviderError`. Never includes request headers (credentials) in errors.
struct APIClient: Sendable {
    let http: any HTTPClient
    let retry: RetryPolicy
    let sleep: @Sendable (Duration) async throws -> Void

    init(
        http: any HTTPClient,
        retry: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.http = http
        self.retry = retry
        self.sleep = sleep
    }

    func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let isLastAttempt = attempt >= retry.maxAttempts
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await http.data(for: request)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard Self.isTransient(error), !isLastAttempt else {
                    throw TicketProviderError.transport(error.localizedDescription)
                }
                try await sleep(retry.backoff(afterAttempt: attempt))
                continue
            }

            switch response.statusCode {
            case 200..<300:
                return data
            case 429:
                let wait = Self.retryAfter(response) ?? retry.backoff(afterAttempt: attempt)
                guard !isLastAttempt, wait <= retry.maxRetryAfter else { throw TicketProviderError.rateLimited }
                try await sleep(wait)
            case 500..<600 where response.statusCode != 501:
                guard !isLastAttempt else {
                    throw TicketProviderError.http(status: response.statusCode, message: Self.errorMessage(in: data))
                }
                try await sleep(retry.backoff(afterAttempt: attempt))
            case 401:
                throw TicketProviderError.unauthorized
            case 403:
                throw TicketProviderError.forbidden(Self.errorMessage(in: data))
            case 404:
                throw TicketProviderError.notFound(request.url?.path() ?? "resource")
            default:
                throw TicketProviderError.http(status: response.statusCode, message: Self.errorMessage(in: data))
            }
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TicketProviderError.invalidResponse("Could not decode \(T.self) from \(request.url?.path() ?? "response"): \(error)")
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains(error.code)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return .seconds(seconds)
    }

    /// Extracts a readable message from Jira (`errorMessages`) or Shortcut (`message`) error bodies.
    static func errorMessage(in data: Data) -> String {
        let message: String
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            message = json["errorMessages"]?[0]?.string
                ?? json["message"]?.string
                ?? json["error"]?.string
                ?? json["errors"]?.objectValues.compactMap(\.string).first
                ?? ""
        } else {
            message = String(decoding: data.prefix(300), as: UTF8.self)
        }
        return String(message.prefix(300))
    }
}

extension URLRequest {
    static func json(_ url: URL, method: String = "GET", headers: [String: String], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DevPilot/0.1", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// Maps with at most `limit` transforms in flight, preserving input order.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ transform: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        func enqueue() {
            let index = next
            group.addTask { (index, try await transform(items[index])) }
            next += 1
        }
        while next < min(limit, items.count) { enqueue() }
        while let (index, result) = try await group.next() {
            results[index] = result
            if next < items.count { enqueue() }
        }
        return results.compactMap { $0 }
    }
}
