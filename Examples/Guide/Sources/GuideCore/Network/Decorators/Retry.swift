import JadeAPI

/// Reintenta la llamada completa hasta `attempts` veces. Es un decorador genérico de AnnotationSwift:
/// no sabe de HTTP (para reintentos conscientes de verbos y status está `@Retries` de JadeAPI).
@Annotation
struct Retry: Decorator {
    let attempts: Int

    init(_ attempts: Int) { self.attempts = max(1, attempts) }

    func decorate<Out>(_ call: Call, _ next: () throws -> Out) rethrows -> Out {
        for _ in 1..<attempts { if let out = try? next() { return out } }
        return try next()
    }

    func decorate<Out>(_ call: Call, isolation: isolated (any Actor)?, _ next: () async throws -> Out) async rethrows -> Out {
        for _ in 1..<attempts { if let out = try? await next() { return out } }
        return try await next()
    }
}
