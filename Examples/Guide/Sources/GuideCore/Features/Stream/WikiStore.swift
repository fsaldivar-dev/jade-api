import JadeAPI
import Observation

/// Pestaña Stream: ediciones de Wikipedia en vivo por SSE.
///
/// Qué enseña: un requisito `kind: .sse` devuelve un `AsyncThrowingStream<ServerEvent, Error>`; se
/// consume con `for try await`; cada evento trae `data` en JSON que `event.decode(...)` convierte en
/// `WikiChange`; y parar es cancelar la `Task`: la conexión se cierra sola.
@MainActor
@Observable
public final class WikiStore {
    /// Las últimas ediciones, la más reciente primero.
    public private(set) var changes: [WikiChange] = []
    public private(set) var received = 0
    public private(set) var isRunning = false
    public private(set) var errorMessage: String?

    private let wiki: any WikiRepository
    private var task: Task<Void, Never>?
    private let keep = 30

    public init(wiki: any WikiRepository) {
        self.wiki = wiki
    }

    public func start() {
        guard task == nil else { return }
        isRunning = true
        errorMessage = nil
        task = Task {
            do {
                for try await event in try await wiki.recentChanges() {
                    let change = try event.decode(WikiChange.self)
                    changes.insert(change, at: 0)
                    if changes.count > keep { changes.removeLast() }
                    received += 1
                }
            } catch is CancellationError {
                // parar no es un error
            } catch {
                errorMessage = describe(error)
            }
            isRunning = false
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
