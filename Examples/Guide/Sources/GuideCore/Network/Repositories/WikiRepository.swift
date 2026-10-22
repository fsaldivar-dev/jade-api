import JadeAPI

/// Servicio `wiki` (stream.wikimedia.org): ediciones de Wikipedia en vivo por Server-Sent Events.
///
/// `kind: .sse` cambia el retorno: en vez de un valor, un stream de `ServerEvent` que empieza al hacer
/// `await` y termina cuando cancelas la `Task` que lo consume.
@Repository(service: "wiki")
public protocol WikiRepository: Sendable {
    @Api("/v2/stream/recentchange", kind: .sse)
    func recentChanges() async throws -> AsyncThrowingStream<ServerEvent, any Error>
}
