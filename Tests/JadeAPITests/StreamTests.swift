import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Fase 3a: streams")
struct StreamTests {

    let mock = MockClient()
    var feed: FeedRepository {
        FeedRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: mock,
                                               interceptors: [CommonHeaders(["X-App": "jade"])]))
    }

    @Test("bytes: los trozos llegan en orden y los adaptadores de petición se aplican")
    func bytes() async throws {
        mock.onStream(.get, "/export") { _ in MockStream(chunks: [Data([1, 2]), Data([3]), Data()]) }
        var received: [Data] = []
        for try await chunk in try await feed.export() { received.append(chunk) }
        #expect(received == [Data([1, 2]), Data([3]), Data()])
        #expect(mock.received.first?.headers["X-App"] == "jade")
    }

    @Test("lines: una línea puede llegar partida en varios trozos; CRLF se acepta; la última sin salto también")
    func lines() async throws {
        mock.onStream(.get, "/log") { _ in .text(["uno\ndo", "s\r\ntr", "es\ncuatro"]) }
        var lines: [String] = []
        for try await line in try await feed.log() { lines.append(line) }
        #expect(lines == ["uno", "dos", "tres", "cuatro"])
    }

    @Test("ndjson: decodifica cada línea, ignora vacías, y el body del POST se manda")
    func ndjson() async throws {
        mock.onStream(.post, "/completions") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            return .text([#"{"index": 0, "text": "Ho"}"#, "\n\n", #"{"index": 1, "text": "la \#(body.contains("prompt") ? "✓" : "✗")"}"#, "\n"])
        }
        var chunks: [Chunk] = []
        for try await chunk in try await feed.complete(prompt: "saluda") { chunks.append(chunk) }
        #expect(chunks == [Chunk(index: 0, text: "Ho"), Chunk(index: 1, text: "la ✓")])
    }

    @Test("sse: id, event, data multilínea, retry, comentarios, y Accept por defecto")
    func sse() async throws {
        mock.onStream(.get, "/events") { request in
            .text([
                ": comentario\n",
                "id: 1\nevent: greet\ndata: hola\ndata: mundo\n\n",
                "retry: 5000\ndata: {\"n\": 2}\n\n",
                "data: sin salto final",
            ])
        }
        var events: [ServerEvent] = []
        for try await event in try await feed.events() { events.append(event) }
        #expect(events.count == 3)
        #expect(events[0] == ServerEvent(id: "1", event: "greet", data: "hola\nmundo"))
        #expect(events[1].id == "1")                       // el id persiste entre eventos
        #expect(events[1].retry == 5000)
        struct N: Decodable { let n: Int }
        #expect(try events[1].decode(N.self).n == 2)
        #expect(events[2].data == "sin salto final")
        #expect(mock.received.first?.headers["Accept"] == "text/event-stream")
    }

    @Test("Un status fuera de 2xx se convierte en HTTPError.status con el body completo antes de entregar el stream")
    func errorStatus() async throws {
        mock.onStream(.get, "/log") { _ in .text(["no ", "autorizado"], status: 401) }
        do { _ = try await feed.log(); Issue.record("debió lanzar") }
        catch let error as HTTPError {
            guard case .status(401, let response) = error else { Issue.record("esperaba .status(401)"); return }
            #expect(response.text == "no autorizado")
        }
    }

    @Test("Cancelar la Task que consume detiene el stream")
    func cancellation() async throws {
        mock.onStream(.get, "/log") { _ in .text(Array(repeating: "x\n", count: 200), interval: .milliseconds(30)) }
        let repo = feed
        let seen = Counter()
        let task = Task {
            for try await _ in try await repo.log() { _ = seen.increment() }
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = try? await task.value
        #expect(seen.increment() < 100)   // 200 líneas a 30 ms serían 6 s; se canceló mucho antes
    }

    @Test("Un transporte sin streaming nativo entrega el body de una pieza")
    func fallback() async throws {
        mock.on(.get, "/log") { _ in MockResponse(body: Data("a\nb\n".utf8)) }   // on, no onStream
        var lines: [String] = []
        for try await line in try await feed.log() { lines.append(line) }
        #expect(lines == ["a", "b"])
    }
}
