import Foundation

/// Todo lo que puede fallar en una llamada, tipado.
public enum HTTPError: Error, CustomStringConvertible {
    /// La ruta o la base no forman una URL válida, o falta un parámetro de ruta.
    case invalidURL(String)
    /// No se pudo codificar el body.
    case encoding(any Error)
    /// Fallo de red antes de obtener respuesta (sin conexión, DNS, TLS, timeout).
    case transport(any Error)
    /// El servidor respondió fuera de 2xx. La respuesta completa viene incluida.
    case status(Int, Response)
    /// La respuesta llegó pero no se pudo decodificar al tipo de retorno.
    case decoding(any Error, Response)
    /// Un `MockClient` recibió una petición sin handler registrado.
    case unmocked(Request)
    /// La tarea fue cancelada.
    case cancelled
    /// Se superó el `timeout` de las opciones del endpoint.
    case timeout(Duration, Request)

    public var description: String {
        switch self {
        case .invalidURL(let reason): "URL inválida: \(reason)"
        case .encoding(let error): "no se pudo codificar el body: \(error)"
        case .transport(let error): "error de red: \(error.localizedDescription)"
        case .status(let code, let response): "HTTP \(code) en \(response.request.method.rawHTTP) \(response.request.path)"
        case .decoding(let error, let response): "no se pudo decodificar la respuesta de \(response.request.path): \(error)"
        case .unmocked(let request): "sin mock para \(request.method.rawHTTP) \(request.path)"
        case .cancelled: "cancelada"
        case .timeout(let duration, let request): "timeout de \(duration) en \(request.method.rawHTTP) \(request.path)"
        }
    }

    /// Código de estado si el error es ``status(_:_:)``.
    public var statusCode: Int? {
        if case .status(let code, _) = self { return code }
        return nil
    }
}
