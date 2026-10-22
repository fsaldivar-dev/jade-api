import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Métricas de transporte")
struct MetricsTests {

    let mock = MockClient()
    func client(_ interceptors: [any Interceptor] = []) -> AppClient {
        AppClient(baseURL: "https://api.ejemplo.com", transport: mock, interceptors: interceptors)
    }

    @Test("MockClient sintetiza métricas: latencia, bytes y protocolo mock")
    func mockMetrics() async throws {
        mock.latency = .milliseconds(20)
        mock.on(.get, "/users/:id") { _ in .json(#"{"id": 1, "name": "Paco"}"#) }
        let response = try await client().performResponse(Endpoint(name: "u", method: .get, path: "/users/1"))
        let metrics = try #require(response.metrics)
        #expect(metrics.duration == .milliseconds(20))
        #expect(metrics.bytesReceived == 25)
        #expect(metrics.protocolName == "mock")
        #expect(response.attempts == 1)
    }

    @Test("@Retries deja el número de intento en la respuesta")
    func attempts() async throws {
        let calls = MetricsCounter()
        mock.on(.get, "/catalog/:id") { _ in calls.next() == 1 ? .status(503) : .json(#"{"id": 2, "name": "ok"}"#) }
        let catalog: CatalogRepository = CatalogRepositoryClient(client: client())
        _ = try await catalog.item(id: 2)   // @Retries(3) en el fixture
        // La respuesta final pasó por el motor con número de intento 2; el interceptor de métricas lo ve.
        let reports = Reports()
        mock.reset()
        calls.reset()
        mock.on(.get, "/catalog/:id") { _ in calls.next() == 1 ? .status(503) : .json(#"{"id": 2, "name": "ok"}"#) }
        let measured: CatalogRepository = CatalogRepositoryClient(client: client([MetricsInterceptor { reports.add($0) }]))
        _ = try await measured.item(id: 2)
        let report = try #require(reports.all.first)
        #expect(report.attempts == 2)
        #expect(report.status == 200)
        #expect(report.succeeded)
    }

    @Test("MetricsInterceptor: informe con petición redactada, status y métricas; en error, sin status")
    func interceptor() async throws {
        let reports = Reports()
        mock.on(.get, "/users/:id") { request in request.path == "/users/1" ? .json(#"{"id": 1, "name": "x"}"#) : .status(500) }
        let users: UsersRepository = UsersRepositoryClient(client: client([
            MetricsInterceptor { reports.add($0) },
            CommonHeaders(["Authorization": "Bearer secreto"]),
        ]))
        _ = try await users.user(id: 1)
        _ = try? await users.user(id: 2)
        let unmocked: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: MockClient(), interceptors: [MetricsInterceptor { reports.add($0) }]))
        _ = try? await unmocked.user(id: 3)

        #expect(reports.all.count == 3)
        #expect(reports.all[0].status == 200)
        #expect(reports.all[0].transport?.protocolName == "mock")
        #expect(reports.all[0].request.headers["Authorization"] == nil)   // el interceptor va por fuera de CommonHeaders
        #expect(reports.all[1].status == 500)
        #expect(reports.all[1].succeeded == false)
        #expect(reports.all[2].status == nil)
        #expect(reports.all[2].error?.contains("sin mock") == true)
        #expect(reports.all.allSatisfy { $0.elapsed >= .zero })
    }

    @Test("MetricsInterceptor redacta credenciales que ya venían en la petición")
    func redaction() async throws {
        let reports = Reports()
        mock.on(.get, "/users/:id") { _ in .json(#"{"id": 1, "name": "x"}"#) }
        let users: UsersRepository = UsersRepositoryClient(client: client([
            CommonHeaders(["Authorization": "Bearer secreto"]),
            MetricsInterceptor { reports.add($0) },
        ]))
        _ = try await users.user(id: 1)
        #expect(reports.all.first?.request.headers["Authorization"] == "•••")
    }

    @Test("RequestLogger muestra duración en ms, protocolo e intento")
    func loggerLine() async throws {
        let lines = Lines()
        let calls = MetricsCounter()
        mock.on(.get, "/catalog/:id") { _ in calls.next() == 1 ? .status(503) : .json(#"{"id": 2, "name": "ok"}"#) }
        let catalog: CatalogRepository = CatalogRepositoryClient(client: client([RequestLogger(.line, sink: { lines.add($0) })]))
        _ = try await catalog.item(id: 2)
        let line = try #require(lines.all.first { $0.hasPrefix("← 200") })
        #expect(line.contains(" ms"))
        #expect(line.contains("mock"))
        #expect(line.contains("intento 2"))
    }

    @Test("Un stream resuelve sus métricas al terminar")
    func streamMetrics() async throws {
        mock.on(.get, "/feed") { _ in .json("abc") }
        let streaming = try await client().performStreaming(Endpoint(name: "feed", method: .get, path: "/feed"))
        for try await _ in streaming.chunks {}
        let metrics = await streaming.metrics.value
        #expect(metrics?.protocolName == "mock")
    }

    @Test("URLSessionClient recoge URLSessionTaskMetrics (con un URLProtocol local)")
    func urlSessionMetrics() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = URLSessionClient(session: URLSession(configuration: configuration))
        let response = try await transport.send(Request(method: .get, url: URL(string: "https://stub.local/ok")!, path: "/ok"))
        #expect(response.status == 200)
        let metrics = try #require(response.metrics)
        #expect(metrics.duration >= .zero)
        #expect(metrics.bytesReceived >= 0)
    }

    @Test("MetricsFuture entrega el valor a quien espera antes y después de resolver")
    func future() async {
        let future = MetricsFuture()
        async let early = future.value
        try? await Task.sleep(for: .milliseconds(10))
        future.resolve(TransportMetrics(duration: .seconds(1)))
        #expect(await early?.duration == .seconds(1))
        #expect(await future.value?.duration == .seconds(1))
        future.resolve(nil)   // se ignora
        #expect(await future.value != nil)
    }
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [MetricsReport] = []
    func add(_ report: MetricsReport) { lock.lock(); reports.append(report); lock.unlock() }
    var all: [MetricsReport] { lock.lock(); defer { lock.unlock() }; return reports }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class MetricsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    func reset() { lock.lock(); count = 0; lock.unlock() }
}

/// Responde 200 "ok" a cualquier petición, sin red. URLSession sigue recogiendo métricas de la tarea.
final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
