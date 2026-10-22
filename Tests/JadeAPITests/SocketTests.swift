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

    @Test("Un transporte sin sockets lanza HTTPError.unsupported")
    func unsupported() async throws {
        let chat: ChatRepository = ChatRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: MockClient()))
        await #expect(throws: HTTPError.self) { _ = try await chat.binary() }
    }
}
