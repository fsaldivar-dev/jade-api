import Foundation

/// Aplica ``RequestOptions`` por dentro de los interceptores del usuario y por fuera del transporte:
/// caché → single-flight → reintentos → timeout → red.
final class OptionsEngine: Sendable {
    private let cache = ResponseCache()
    private let flights = InFlight()

    func send(_ request: Request, options: RequestOptions, transport: @escaping @Sendable (Request) async throws -> Response) async throws -> Response {
        if let ttl = options.cache, let cached = await cache.get(request.cacheKey) {
            _ = ttl
            return cached
        }
        let perform: @Sendable () async throws -> Response = {
            let response = try await self.withRetry(options.retry, request: request) {
                try await self.withTimeout(options.timeout, request: request, transport: transport)
            }
            if let ttl = options.cache, response.isSuccess {
                await self.cache.set(request.cacheKey, response, ttl: ttl)
            }
            return response
        }
        if options.singleFlight {
            return try await flights.run(key: request.cacheKey, perform)
        }
        return try await perform()
    }

    // MARK: Reintentos

    private func withRetry(_ policy: RetryPolicy?, request: Request, _ attempt: @Sendable () async throws -> Response) async throws -> Response {
        guard let policy, policy.attempts > 1 else { return try await attempt() }
        var lastError: (any Error)?
        for number in 1...policy.attempts {
            do {
                let response = try await attempt()
                guard number < policy.attempts, RetryPolicy.shouldRetry(status: response.status) else { return response }
                try await sleep(policy: policy, attempt: number, retryAfter: response.header("Retry-After"))
                continue
            } catch let error as HTTPError {
                switch error {
                case .transport, .timeout:
                    lastError = error
                    guard number < policy.attempts else { throw error }
                    try await sleep(policy: policy, attempt: number, retryAfter: nil)
                default:
                    throw error
                }
            }
        }
        throw lastError ?? HTTPError.transport(URLError(.unknown))
    }

    private func sleep(policy: RetryPolicy, attempt: Int, retryAfter: String?) async throws {
        var delay = policy.delay(forAttempt: attempt)
        if policy.honorsRetryAfter, let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            delay = .seconds(seconds)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
    }

    // MARK: Timeout

    private func withTimeout(_ timeout: Duration?, request: Request, transport: @escaping @Sendable (Request) async throws -> Response) async throws -> Response {
        guard let timeout else { return try await transport(request) }
        var request = request
        request.timeout = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let timed = request
        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { try await transport(timed) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HTTPError.timeout(timeout, timed)
            }
            guard let first = try await group.next() else { throw HTTPError.cancelled }
            group.cancelAll()
            return first
        }
    }
}

extension Request {
    /// Clave de caché y de deduplicación: verbo + URL + body.
    var cacheKey: String { "\(method.rawHTTP) \(url.absoluteString) \(body?.hashValue ?? 0)" }
}

/// Caché en memoria con expiración por entrada.
actor ResponseCache {
    private var entries: [String: (response: Response, expires: ContinuousClock.Instant)] = [:]

    func get(_ key: String) -> Response? {
        guard let entry = entries[key] else { return nil }
        if entry.expires <= .now { entries[key] = nil; return nil }
        return entry.response
    }

    func set(_ key: String, _ response: Response, ttl: Duration) {
        entries[key] = (response, .now + ttl)
    }
}

/// Peticiones idénticas en vuelo comparten la misma `Task`.
actor InFlight {
    private var tasks: [String: Task<Response, any Error>] = [:]

    func run(key: String, _ perform: @escaping @Sendable () async throws -> Response) async throws -> Response {
        if let existing = tasks[key] { return try await existing.value }
        let task = Task { try await perform() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}
