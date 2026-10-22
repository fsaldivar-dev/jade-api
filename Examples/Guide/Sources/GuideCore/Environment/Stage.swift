import Foundation

/// Entornos de la guía. `live` habla con APIs públicas reales; `mock` con un servidor falso en memoria.
///
/// En un proyecto de Xcode esto sale de `Environment(bundle: .main)`, que lee el Info.plist alimentado
/// por los `.xcconfig` de `Config/` (uno por Build Configuration). Este ejemplo es un paquete SwiftPM
/// sin Info.plist, así que describe la misma configuración en código, con el mismo formato.
public enum Stage: String, CaseIterable, Identifiable, Sendable {
    case live, mock

    public var id: String { rawValue }

    /// Cinco servicios. `auth` y `catalog` comparten host: un servicio es un nombre lógico.
    public var configuration: [String: Any] {
        switch self {
        case .live: ["stage": "live", "services": [
            "auth":    ["baseURL": "https://dummyjson.com"],
            "catalog": ["baseURL": "https://dummyjson.com", "timeout": "10"],
            "wiki":    ["baseURL": "https://stream.wikimedia.org"],
            "photos":  ["baseURL": "https://picsum.photos"],
            "echo":    ["baseURL": "https://echo.websocket.org"],
        ]]
        case .mock: ["stage": "mock", "services": [
            "auth":    ["baseURL": "https://auth.mock.local"],
            "catalog": ["baseURL": "https://catalog.mock.local", "timeout": "10"],
            "wiki":    ["baseURL": "https://wiki.mock.local"],
            "photos":  ["baseURL": "https://photos.mock.local"],
            "echo":    ["baseURL": "https://echo.mock.local"],
        ]]
        }
    }

    /// `auth → https://…  ·  catalog → https://…`, para mostrar en la UI.
    public var servicesSummary: String {
        ((configuration["services"] as? [String: [String: Any]]) ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value["baseURL"] ?? "")" }
            .joined(separator: "  ·  ")
    }

    /// Entorno activo: `--stage=live`, `JADE_STAGE=live`, o el valor por defecto.
    public static func resolve(arguments: [String] = CommandLine.arguments,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fallback: Stage) -> Stage {
        if let argument = arguments.first(where: { $0.hasPrefix("--stage=") }),
           let stage = Stage(rawValue: String(argument.dropFirst("--stage=".count))) {
            return stage
        }
        if let name = environment["JADE_STAGE"], let stage = Stage(rawValue: name) {
            return stage
        }
        return fallback
    }
}
