import Foundation

/// Progreso agregado de un grupo: cuántas terminaron (bien o mal) de cuántas.
public struct GroupProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public var fractionCompleted: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// Acumula las operaciones de un grupo homogéneo. Se construye dentro de `client.group { group in … }`.
/// El closure de construcción corre en el aislamiento de quien llama (por eso `group` recibe `#isolation`),
/// así puede leer estado de un `@MainActor`; las operaciones añadidas sí deben ser `@Sendable`.
public struct RequestGroup<Element: Sendable>: ~Copyable {
    public typealias Operation = @Sendable () async throws -> Element
    var operations: [Operation] = []

    /// Añade una operación. Los resultados conservan el orden en que se añadieron.
    public mutating func add(_ operation: @escaping Operation) {
        operations.append(operation)
    }
}

extension AppClient {

    /// Lanza N operaciones iguales con límite de concurrencia y devuelve los resultados **en el orden
    /// en que se añadieron**. Si una falla, cancela las demás y lanza (fail-fast). Para tolerar fallos
    /// usa ``groupSettled(maxConcurrent:progress:isolation:_:)``.
    ///
    /// ```swift
    /// let users = try await client.group(maxConcurrent: 3) { group in
    ///     for id in ids { group.add { try await repo.getUser(id: id) } }
    /// }
    /// ```
    public func group<Element: Sendable>(
        maxConcurrent: Int = 4,
        progress: (@Sendable (GroupProgress) -> Void)? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ build: (inout RequestGroup<Element>) -> Void
    ) async throws -> [Element] {
        var group = RequestGroup<Element>()
        build(&group)
        let operations = group.operations
        let settled = try await Self.run(operations, maxConcurrent: maxConcurrent, failFast: true, progress: progress)
        return try settled.map { try $0.get() }
    }

    /// Como ``group(maxConcurrent:progress:isolation:_:)`` pero no lanza: ejecuta todas y devuelve un `Result` por
    /// operación, en orden. Para tolerar hasta N fallos, cuenta los `.failure` del resultado.
    public func groupSettled<Element: Sendable>(
        maxConcurrent: Int = 4,
        progress: (@Sendable (GroupProgress) -> Void)? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ build: (inout RequestGroup<Element>) -> Void
    ) async -> [Result<Element, any Error>] {
        var group = RequestGroup<Element>()
        build(&group)
        let operations = group.operations
        return (try? await Self.run(operations, maxConcurrent: maxConcurrent, failFast: false, progress: progress)) ?? []
    }

    /// Pocas operaciones **distintas** a la vez, cada una con su tipo. Si una falla, cancela las otras.
    /// No tiene límite de concurrencia: para N iguales usa ``group(maxConcurrent:progress:isolation:_:)``;
    /// para dos o tres sin librería, `async let` del lenguaje hace lo mismo.
    ///
    /// ```swift
    /// let (featured, offers, categories) = try await client.all(
    ///     { try await catalog.featured() },
    ///     { try await catalog.offers() },
    ///     { try await catalog.categories() }
    /// )
    /// ```
    public func all<each Element: Sendable>(
        _ operations: repeat @escaping @Sendable () async throws -> each Element
    ) async throws -> (repeat each Element) {
        let tasks = (repeat Task { try await (each operations)() })
        return try await withTaskCancellationHandler {
            do {
                return (repeat try await (each tasks).value)
            } catch {
                for task in repeat each tasks { task.cancel() }
                throw error
            }
        } onCancel: {
            for task in repeat each tasks { task.cancel() }
        }
    }

    // MARK: - Motor

    private static func run<Element: Sendable>(
        _ operations: [@Sendable () async throws -> Element],
        maxConcurrent: Int,
        failFast: Bool,
        progress: (@Sendable (GroupProgress) -> Void)?
    ) async throws -> [Result<Element, any Error>] {
        let limit = max(1, maxConcurrent)
        let total = operations.count
        var results = [Result<Element, any Error>?](repeating: nil, count: total)
        guard total > 0 else { return [] }

        try await withThrowingTaskGroup(of: (Int, Result<Element, any Error>).self) { group in
            var next = 0
            func launch() {
                let index = next
                let operation = operations[index]
                group.addTask {
                    do { return (index, .success(try await operation())) }
                    catch { return (index, .failure(error)) }
                }
                next += 1
            }
            while next < min(limit, total) { launch() }

            var completed = 0
            while let (index, result) = try await group.next() {
                results[index] = result
                completed += 1
                progress?(GroupProgress(completed: completed, total: total))
                if failFast, case .failure(let error) = result {
                    group.cancelAll()
                    throw error
                }
                if next < total { launch() }
            }
        }
        return results.map { $0! }
    }
}
