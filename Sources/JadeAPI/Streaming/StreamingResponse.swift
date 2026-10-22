import Foundation

/// Respuesta cuyo body llega por partes. Status y headers están disponibles de inmediato;
/// los bytes, conforme el servidor los envía.
public struct StreamingResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let request: Request
    /// Trozos de body en el orden de llegada. Termina cuando el servidor cierra o la tarea se cancela.
    public let chunks: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String] = [:], request: Request, chunks: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = headers
        self.request = request
        self.chunks = chunks
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Respuesta de una sola pieza, para transportes que no saben transmitir por partes.
    public init(_ response: Response) {
        self.init(status: response.status, headers: response.headers, request: response.request,
                  chunks: AsyncThrowingStream { continuation in
                      if !response.body.isEmpty { continuation.yield(response.body) }
                      continuation.finish()
                  })
    }
}

/// Evento de Server-Sent Events (text/event-stream).
public struct ServerEvent: Sendable, Equatable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retry: Int?

    public init(id: String? = nil, event: String? = nil, data: String, retry: Int? = nil) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }

    /// Decodifica `data` como JSON.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self, with decoder: JSONDecoder = JSONDecoder()) throws -> Value {
        try decoder.decode(Value.self, from: Data(data.utf8))
    }
}

/// Parsers de los formatos de stream soportados. Operan sobre trozos arbitrarios: una línea puede
/// llegar partida en dos chunks.
public enum StreamParsing {

    /// Líneas UTF-8 terminadas en `\n` (se acepta `\r\n`). La última línea sin salto también se entrega.
    public static func lines(_ chunks: AsyncThrowingStream<Data, any Error>) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await chunk in chunks {
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                            var line = buffer[buffer.startIndex..<newline]
                            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            buffer.removeSubrange(buffer.startIndex...newline)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// NDJSON: un objeto JSON por línea; las líneas vacías se ignoran.
    public static func ndjson<Element: Decodable & Sendable>(_ chunks: AsyncThrowingStream<Data, any Error>, as type: Element.Type = Element.self, decoder: JSONDecoder) -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines(chunks) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        continuation.yield(try decoder.decode(Element.self, from: Data(line.utf8)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Server-Sent Events: campos `id`, `event`, `data` (varias líneas se unen con `\n`), `retry`;
    /// una línea en blanco despacha el evento; las líneas que empiezan con `:` son comentarios.
    public static func serverEvents(_ chunks: AsyncThrowingStream<Data, any Error>) -> AsyncThrowingStream<ServerEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var id: String?, event: String?, retry: Int?
                var data: [String] = []
                func dispatch() {
                    guard !data.isEmpty else { id = nil; event = nil; retry = nil; return }
                    continuation.yield(ServerEvent(id: id, event: event, data: data.joined(separator: "\n"), retry: retry))
                    event = nil; retry = nil; data = []
                }
                do {
                    for try await line in lines(chunks) {
                        if line.isEmpty { dispatch(); continue }
                        if line.hasPrefix(":") { continue }
                        let (field, value) = split(line)
                        switch field {
                        case "id": id = value
                        case "event": event = value
                        case "data": data.append(value)
                        case "retry": retry = Int(value)
                        default: continue
                        }
                    }
                    dispatch()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.hasPrefix(" ") { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}
