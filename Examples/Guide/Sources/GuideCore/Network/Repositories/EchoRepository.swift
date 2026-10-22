import JadeAPI

/// Servicio `echo` (echo.websocket.org): un WebSocket público que devuelve lo que le mandas.
///
/// `@Socket` en vez de `@Api`. La política de resiliencia va en la declaración, como cualquier otra
/// opción: si la conexión cae, reconecta con espera exponencial (1 s, 2 s, 4 s… hasta 15 s) y manda
/// un ping cada 20 s para detectar conexiones muertas. Sin `reconnect:` una caída termina `messages`.
@Repository(service: "echo")
public protocol EchoRepository: Sendable {
    @Socket("/", reconnect: .exponential(.seconds(1), max: .seconds(15)), keepAlive: .seconds(20))
    func connect() async throws -> Socket<String, String>
}
