import Foundation

/// Un entorno: a dónde apuntan las peticiones y con qué transporte.
///
/// ```swift
/// enum Stage: String, StageProtocol {
///     case dev, prod, mock
///     var baseURL: URL {
///         switch self {
///         case .dev: URL(string: "https://dev.api.ejemplo.com")!
///         case .prod: URL(string: "https://api.ejemplo.com")!
///         case .mock: URL(string: "https://mock.local")!
///         }
///     }
///     var transport: any HTTPClient {
///         self == .mock ? Fixtures.client : URLSessionClient()
///     }
/// }
/// ```
public protocol StageProtocol: Sendable {
    var baseURL: URL { get }
    /// Transporte del entorno. Por defecto `URLSession`.
    var transport: any HTTPClient { get }
}

extension StageProtocol {
    public var transport: any HTTPClient { URLSessionClient() }
}

extension StageProtocol where Self: RawRepresentable, Self.RawValue == String {

    /// Resuelve el entorno activo, en este orden: argumento `--stage=<nombre>`, variable de
    /// entorno `JADE_STAGE`, y si no, `fallback`.
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: Self
    ) -> Self {
        if let argument = arguments.first(where: { $0.hasPrefix("--stage=") }),
           let stage = Self(rawValue: String(argument.dropFirst("--stage=".count))) {
            return stage
        }
        if let name = environment["JADE_STAGE"], let stage = Self(rawValue: name) {
            return stage
        }
        return fallback
    }
}
