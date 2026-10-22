import Foundation

/// Entornos de la app. En un proyecto de Xcode esto sale de `Environment(bundle: .main)`, que lee el
/// Info.plist alimentado por los `.xcconfig` de `Config/` (uno por Build Configuration). Este ejemplo es
/// un paquete SwiftPM sin Info.plist, así que describe la misma configuración en código.
public enum Stage: String, CaseIterable, Identifiable, Sendable {
    case dev, prod, mock

    public var id: String { rawValue }

    /// Dos servicios, `auth` y `catalog`, cada uno con su base. Mismo formato que el Info.plist.
    public var configuration: [String: Any] {
        switch self {
        case .dev: ["stage": "dev", "services": [
            "auth": ["baseURL": "https://auth.dev.ejemplo.com"],
            "catalog": ["baseURL": "https://catalog.dev.ejemplo.com/v2", "timeout": "10", "retries": "2"],
        ]]
        case .prod: ["stage": "prod", "services": [
            "auth": ["baseURL": "https://auth.ejemplo.com"],
            "catalog": ["baseURL": "https://catalog.ejemplo.com/v2", "timeout": "10", "retries": "2"],
        ]]
        case .mock: ["stage": "mock", "services": [
            "auth": ["baseURL": "https://auth.mock.local"],
            "catalog": ["baseURL": "https://catalog.mock.local/v2", "retries": "2"],
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

    /// Entorno activo: `--stage=dev`, `JADE_STAGE=dev`, o el valor por defecto.
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
