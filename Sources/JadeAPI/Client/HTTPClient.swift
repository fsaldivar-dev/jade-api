import Foundation

/// El transporte: recibe una ``Request`` ya formada y devuelve una ``Response``.
/// URLSession por defecto; ``MockClient`` en tests; Alamofire en una iteración posterior.
public protocol HTTPClient: Sendable {
    func send(_ request: Request) async throws -> Response
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
}
