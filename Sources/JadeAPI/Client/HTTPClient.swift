import Foundation

/// El transporte: recibe una ``Request`` ya formada y devuelve una ``Response``.
/// URLSession por defecto; `MockClient` (JadeTesting) en tests; Alamofire en una iteración posterior.
public protocol HTTPClient: Sendable {
    func send(_ request: Request) async throws -> Response
    /// Respuesta por partes. Por defecto cae a ``send(_:)`` y entrega el body de una pieza, así
    /// cualquier transporte sirve para streams aunque no transmita incrementalmente.
    func stream(_ request: Request) async throws -> StreamingResponse
}

extension HTTPClient {
    public func stream(_ request: Request) async throws -> StreamingResponse {
        StreamingResponse(try await send(request))
    }
}

/// Transporte sobre `URLSession` con `async/await`. Respeta la cancelación de la `Task`.
public struct URLSessionClient: HTTPClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: Request) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request.urlRequest)
        } catch is CancellationError {
            throw HTTPError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw HTTPError.cancelled
        } catch {
            throw HTTPError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.transport(URLError(.badServerResponse))
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return Response(status: http.statusCode, headers: headers, body: data, request: request)
    }

    /// `URLSession.bytes(for:)`: los trozos se entregan conforme llegan (hasta 16 KB por chunk).
    public func stream(_ request: Request) async throws -> StreamingResponse {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request.urlRequest)
        } catch is CancellationError {
            throw HTTPError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw HTTPError.cancelled
        } catch {
            throw HTTPError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.transport(URLError(.badServerResponse)) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(16 * 1024)
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 16 * 1024 { continuation.yield(buffer); buffer.removeAll(keepingCapacity: true) }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPError.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return StreamingResponse(status: http.statusCode, headers: headers, request: request, chunks: chunks)
    }
}
