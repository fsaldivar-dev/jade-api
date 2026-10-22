import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Fase 3c: WebSocket contra un servidor local", .serialized)
struct SocketTests {

    /// Eco de texto; para JSON responde con la longitud; "cierra" hace que el servidor no conteste.
    static func makeServer() async throws -> LocalWebSocketServer {
        try await LocalWebSocketServer.start { text in
            if text == "silencio" { return nil }
            if text.hasPrefix("{") {
                struct In: Decodable { let text: String }
                let incoming = (try? JSONDecoder().decode(In.self, from: Data(text.utf8)))?.text ?? ""
                return #"{"text": "\#(incoming)", "length": \#(incoming.count)}"#
            }
            return text
        }
    }

    @Test("Texto: la ruta con :room se resuelve, los frames hacen eco y close termina messages")
    func textEcho() async throws {
        let server = try await Self.makeServer()
        defer { server.stop() }
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.echo(room: "general")
        #expect(socket.request.url.absoluteString == "ws://127.0.0.1:\(server.port)/ws/echo/general")

        try await socket.send("hola")
        try await socket.send("mundo")
        var received: [String] = []
        for try await message in socket.messages {
            received.append(message)
            if received.count == 2 { socket.close() }
        }
        #expect(received == ["hola", "mundo"])
    }

    @Test("JSON: Outgoing se codifica y Incoming se decodifica; el header del handshake viaja")
    func json() async throws {
        let server = try await Self.makeServer()
        defer { server.stop() }
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.json(token: "Bearer x")
        #expect(socket.request.headers["token"] == "Bearer x")
        try await socket.send(Outgoing(text: "¡hola!"))
        var first: Incoming?
        for try await message in socket.messages { first = message; break }
        #expect(first == Incoming(text: "¡hola!", length: 6))
        socket.close()
    }

    @Test("Binario: Data viaja como frame binario y vuelve igual; ping responde")
    func binary() async throws {
        let server = try await Self.makeServer()
        defer { server.stop() }
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.binary()
        try await socket.ping()
        try await socket.send(Data([0, 1, 2, 255]))
        var first: Data?
        for try await message in socket.messages { first = message; break }
        #expect(first == Data([0, 1, 2, 255]))
        socket.close()
    }

    @Test("Handshake rechazado: no hay servidor en ese puerto y el requisito lanza")
    func handshakeFailure() async throws {
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: "http://127.0.0.1:1", transport: URLSessionClient()))
        await #expect(throws: HTTPError.self) { _ = try await chat.binary() }
    }

    @Test("ws:// solo se permite en Debug; wss:// siempre")
    func policy() throws {
        #expect(throws: HTTPError.self) { try SecurityPolicy(allowsInsecureHTTP: false).validate(URL(string: "ws://a.b")!) }
        try SecurityPolicy(allowsInsecureHTTP: false).validate(URL(string: "wss://a.b")!)
        try SecurityPolicy.default.validate(URL(string: "ws://a.b")!)
    }

    // MARK: Reconexión

    /// Recoge `events` en segundo plano y permite esperar a uno concreto.
    final class Events: @unchecked Sendable {
        private let task: Task<Void, Never>
        init(_ events: AsyncStream<SocketEvent>) {
            let store = Store()
            task = Task { for await event in events { store.append(event) } }
            self.store = store
        }
        private let store: Store
        final class Store: @unchecked Sendable {
            private let lock = NSLock(); private var list: [SocketEvent] = []
            func append(_ e: SocketEvent) { lock.lock(); list.append(e); lock.unlock() }
            var all: [SocketEvent] { lock.lock(); defer { lock.unlock() }; return list }
        }
        var all: [SocketEvent] { store.all }
        func wait(timeout: Duration = .seconds(3), for predicate: @escaping (SocketEvent) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if all.contains(where: predicate) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        func count(_ predicate: (SocketEvent) -> Bool) -> Int { all.filter(predicate).count }
    }

    @Test("Con política: la caída no termina messages, events avisa y el handshake se repite")
    func reconnects() async throws {
        let server = try await Self.makeServer()
        defer { server.stop() }
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.resilient(room: "r")
        let events = Events(socket.events)
        var iterator = socket.messages.makeAsyncIterator()

        try await socket.send("antes")
        #expect(try await iterator.next() == "antes")
        #expect(server.acceptedConnections == 1)

        server.dropConnections()
        #expect(await events.wait { if case .connected(attempt: 1) = $0 { true } else { false } })
        #expect(server.acceptedConnections == 2)
        #expect(socket.isConnected)

        try await socket.send("después")
        #expect(try await iterator.next() == "después")      // el mismo stream sigue vivo
        socket.close()

        #expect(events.count { if case .disconnected = $0 { true } else { false } } == 1)
        #expect(events.count { if case .reconnecting(attempt: 1, _) = $0 { true } else { false } } == 1)
        #expect(await events.wait { if case .closed(code: 1000) = $0 { true } else { false } })
    }

    @Test("Sin política: la caída termina messages con error, como siempre")
    func noPolicy() async throws {
        let server = try await Self.makeServer()
        defer { server.stop() }
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.echo(room: "x")
        #expect(socket.policy.reconnect == nil)
        server.dropConnections()
        await #expect(throws: (any Error).self) {
            for try await _ in socket.messages {}
        }
        #expect(!socket.isConnected)
    }

    @Test("send mientras reconecta lanza SocketDisconnected")
    func sendWhileDown() async throws {
        let server = try await Self.makeServer()
        defer { server.stop() }
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.slowReconnect()
        let events = Events(socket.events)
        server.dropConnections()
        #expect(await events.wait { if case .disconnected = $0 { true } else { false } })
        #expect(!socket.isConnected)
        await #expect(throws: SocketDisconnected.self) { try await socket.send("perdido") }
        socket.close()
    }

    @Test("maxReconnects: tras rendirse, messages termina con el último error y events se cierra")
    func givesUp() async throws {
        let server = try await Self.makeServer()
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.limited()
        let events = Events(socket.events)
        server.stop()                                        // nadie escucha: cada intento falla
        await #expect(throws: (any Error).self) {
            for try await _ in socket.messages {}
        }
        #expect(events.count { if case .reconnecting = $0 { true } else { false } } == 2)
        #expect(await events.wait { if case .closed = $0 { true } else { false } })
        #expect(!socket.isConnected)
    }

    @Test("reconnect() fuerza una reconexión por la política y el mismo stream sigue")
    func forcedReconnect() async throws {
        let server = try await Self.makeServer()
        defer { server.stop() }
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: server.baseURL, transport: URLSessionClient()))
        let socket = try await chat.resilient(room: "f")
        let events = Events(socket.events)
        var iterator = socket.messages.makeAsyncIterator()
        socket.reconnect()
        #expect(await events.wait { if case .connected(attempt: 1) = $0 { true } else { false } })
        try await socket.send("otra vez")
        #expect(try await iterator.next() == "otra vez")
        socket.close()
        socket.reconnect()   // después de close no hace nada
        #expect(!socket.isConnected)
    }

    @Test("Qué reconecta y qué no")
    func policyTable() {
        typealias S = Socket<String, String>
        #expect(S.shouldReconnect(after: SocketClosed(code: 1006, reason: nil)))
        #expect(S.shouldReconnect(after: SocketClosed(code: 1011, reason: nil)))
        #expect(S.shouldReconnect(after: URLError(.networkConnectionLost)))
        #expect(!S.shouldReconnect(after: SocketClosed(code: 1000, reason: nil)))
        #expect(!S.shouldReconnect(after: SocketClosed(code: 1008, reason: "policy")))
        #expect(!S.shouldReconnect(after: SocketClosed(code: 4401, reason: "app")))
        #expect(!S.shouldReconnect(after: CancellationError()))
        let request = Request(method: .get, url: URL(string: "wss://a.b")!, path: "/")
        #expect(!S.shouldReconnect(after: HTTPError.status(401, Response(status: 401, request: request))))
        #expect(S.shouldReconnect(after: HTTPError.status(503, Response(status: 503, request: request))))
    }

    @Test("Un transporte sin sockets lanza HTTPError.unsupported")
    func unsupported() async throws {
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: MockClient()))
        await #expect(throws: HTTPError.self) { _ = try await chat.binary() }
    }
}
