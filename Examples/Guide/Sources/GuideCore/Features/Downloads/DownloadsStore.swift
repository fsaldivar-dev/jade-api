import Foundation
import JadeAPI
import Observation

/// Pestaña Descargas: cinco fotos en una cola con dos descargas a la vez.
///
/// Qué enseña: un requisito `kind: .download` devuelve un `Download`; `DownloadQueue(maxConcurrent:)`
/// los arranca cuando hay hueco; `queue.progress` da el avance agregado; `queue.settled()` espera a
/// todas y devuelve un `Result` por archivo, así una foto fallida no cancela a las demás.
@MainActor
@Observable
public final class DownloadsStore {
    public struct Item: Identifiable, Sendable {
        public let seed: String
        public var file: URL?
        public var error: String?
        public var id: String { seed }
    }

    public private(set) var items: [Item] = []
    public private(set) var progress = QueueProgress.empty
    public private(set) var isRunning = false

    private let photos: any PhotosRepository
    private let seeds = ["jade-1", "jade-2", "jade-3", "jade-4", "jade-5"]

    public init(photos: any PhotosRepository) {
        self.photos = photos
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        items = seeds.map { Item(seed: $0) }

        let queue = DownloadQueue(maxConcurrent: 2)
        let photos = self.photos
        for seed in seeds {
            await queue.enqueue { try await photos.photo(seed: seed) }
        }
        // El progreso agregado llega por un stream; lo observamos mientras esperamos a la cola.
        let observer = Task { for await progress in queue.progress { self.progress = progress } }
        let results = await queue.settled()
        observer.cancel()
        progress = await queue.summary

        for (index, result) in results.enumerated() {
            switch result {
            case .success(let url): items[index].file = url
            case .failure(let error): items[index].error = describe(error)
            }
        }
        isRunning = false
    }

    public func clear() {
        for item in items { if let file = item.file { try? FileManager.default.removeItem(at: file) } }
        items = []
        progress = QueueProgress.empty
    }
}
