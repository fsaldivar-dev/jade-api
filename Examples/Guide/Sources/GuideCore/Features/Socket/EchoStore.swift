import JadeAPI
import Observation

/// Pestaña Socket: un WebSocket de eco con reconexión.
///
/// Qué enseña: `@Socket` devuelve un `Socket<String, String>`; `send` manda; `messages` es un stream
/// que sobrevive a las caídas gracias a `reconnect:` en la declaración; `events` cuenta lo que pasa por
/// debajo (`.disconnected`, `.reconnecting`, `.connected`); y `reconnect()` fuerza una, como haría una
/// app al volver de segundo plano. `send` sin conexión lanza `SocketDisconnected`: no hay cola oculta.
@MainActor
@Observable
public final class EchoStore {
    public private(set) var received: [String] = []
    public private(set) var events: [String] = []
    public private(set) var status = "sin conexión"
    public private(set) var errorMessage: String?
    public var isConnected: Bool { socket?.isConnected ?? false }

    private let echo: any EchoRepository
    private var socket: Socket<String, String>?
    private var tasks: [Task<Void, Never>] = []

    public init(echo: any EchoRepository) {
        self.echo = echo
    }

    public func connect() async {
        guard socket == nil else { return }
        errorMessage = nil
        do {
            let socket = try await echo.connect()
            self.socket = socket
            status = "conectado"
            tasks = [
                Task { await self.listen(to: socket) },
                Task { await self.watch(socket) },
            ]
        } catch {
            errorMessage = describe(error)
        }
    }

    public func send(_ text: String) async {
        guard let socket else { return }
        do {
            try await socket.send(text)
        } catch {
            errorMessage = describe(error)       // SocketDisconnected mientras reconecta
        }
    }

    /// Lo que haría la app al volver de segundo plano o cuando cambia la red.
    public func forceReconnect() {
        socket?.reconnect()
    }

    public func disconnect() {
        socket?.close()
        socket = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        status = "sin conexión"
    }

    private func listen(to socket: Socket<String, String>) async {
        do {
            for try await message in socket.messages { received.insert(message, at: 0) }
        } catch {
            errorMessage = describe(error)       // solo llega aquí si la política se rindió
        }
    }

    private func watch(_ socket: Socket<String, String>) async {
        for await event in socket.events {
            switch event {
            case .connected(let attempt):
                status = attempt == 0 ? "conectado" : "reconectado (intento \(attempt))"
                events.insert("● conectado, intento \(attempt)", at: 0)
            case .disconnected(let error):
                status = "caído"
                events.insert("○ caído: \(error)", at: 0)
            case .reconnecting(let attempt, let after):
                status = "reconectando…"
                events.insert("↻ reconectando #\(attempt) en \(after.millisecondsText)", at: 0)
            case .closed(let code):
                status = "cerrado (\(code))"
                events.insert("■ cerrado con código \(code)", at: 0)
            }
        }
    }
}
