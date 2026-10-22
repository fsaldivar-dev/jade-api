import Foundation

/// Envuelve el HTTP crudo: recibe la ``Request`` y una continuación `next` que la manda a la red
/// (o al siguiente interceptor). Puede mutar la petición, cortar, reintentar o transformar la respuesta.
///
/// Regla de bolsillo: **interceptor** si tocas HTTP (headers, status, bytes); **decorador** si tocas la
/// llamada de dominio; **transformador** si tocas datos. El refresh de token es el interceptor
/// canónico: necesita ver el 401 y repetir la misma petición con otro header.
///
/// ```swift
/// struct SignRequest: Interceptor {
///     func intercept(_ request: Request, next: Next) async throws -> Response {
///         var request = request
///         request.headers["X-Signature"] = sign(request.body)
///         return try await next(request)
///     }
/// }
/// ```
public protocol Interceptor: Sendable {
    typealias Next = @Sendable (Request) async throws -> Response
    func intercept(_ request: Request, next: Next) async throws -> Response
}

/// Interceptor que solo toca la petición antes de enviarla.
public protocol RequestAdapter: Interceptor {
    func adapt(_ request: Request) async throws -> Request
}

extension RequestAdapter {
    public func intercept(_ request: Request, next: Next) async throws -> Response {
        try await next(try await adapt(request))
    }
}

/// Interceptor que solo toca la respuesta después de recibirla.
public protocol ResponseInterceptor: Interceptor {
    func process(_ response: Response) async throws -> Response
}

extension ResponseInterceptor {
    public func intercept(_ request: Request, next: Next) async throws -> Response {
        try await process(try await next(request))
    }
}

/// Composición: el primero de la lista es el más externo; el último habla con el transporte.
public enum InterceptorChain {
    public static func run(_ interceptors: [any Interceptor], request: Request, transport: any HTTPClient) async throws -> Response {
        try await step(interceptors[...], request: request, transport: transport)
    }

    private static func step(_ remaining: ArraySlice<any Interceptor>, request: Request, transport: any HTTPClient) async throws -> Response {
        guard let current = remaining.first else { return try await transport.send(request) }
        let rest = remaining.dropFirst()
        return try await current.intercept(request) { next in
            try await step(rest, request: next, transport: transport)
        }
    }
}
