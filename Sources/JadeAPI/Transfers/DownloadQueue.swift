import Foundation

/// Avance agregado de una cola de descargas.
public struct QueueProgress: Sendable, Equatable {
    public var completed: Int
    public var failed: Int
    public var total: Int
    public var bytesTransferred: Int64
    public var totalBytes: Int64?

    public var fractionCompleted: Double {
        if let totalBytes, totalBytes > 0 { return min(1, Double(bytesTransferred) / Double(totalBytes)) }
        return total == 0 ? 1 : Double(completed + failed) / Double(total)
    }
}

/// Cola de descargas con límite de concurrencia y progreso agregado.
///
/// ```swift
/// let queue = DownloadQueue(maxConcurrent: 2)
/// for id in ids { await queue.enqueue { try await files.export(id: id) } }
/// for await progress in await queue.progress { print(progress.fractionCompleted) }
/// let files = try await queue.results()
/// ```
public actor DownloadQueue {
    public typealias Start = @Sendable () async throws -> Download

    private struct Item { let id: Int; let start: Start; var download: Download?; var result: Result<URL, any Error>?; var progress = TransferProgress.zero }

    private let maxConcurrent: Int
    private var items: [Item] = []
    private var running = 0
    private var nextIndex = 0
    private var progressContinuation: AsyncStream<QueueProgress>.Continuation?
    public nonisolated let progress: AsyncStream<QueueProgress>
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
        var continuation: AsyncStream<QueueProgress>.Continuation!
        progress = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        progressContinuation = continuation
    }

    /// Añade una descarga; empieza cuando hay hueco. Devuelve su posición.
    @discardableResult
    public func enqueue(_ start: @escaping Start) -> Int {
        let id = items.count
        items.append(Item(id: id, start: start))
        pump()
        return id
    }

    public var summary: QueueProgress { snapshot() }

    /// Espera a que terminen todas y devuelve los archivos en orden de alta; lanza el primer error.
    public func results() async throws -> [URL] {
        await waitUntilDone()
        return try items.map { try $0.result!.get() }
    }

    /// Como ``results()`` pero sin lanzar.
    public func settled() async -> [Result<URL, any Error>] {
        await waitUntilDone()
        return items.map { $0.result! }
    }

    public func cancelAll() {
        for item in items { item.download?.cancel() }
    }

    // MARK: - Motor

    private func pump() {
        while running < maxConcurrent, nextIndex < items.count {
            let index = nextIndex
            nextIndex += 1
            running += 1
            Task { await self.run(index) }
        }
    }

    private func run(_ index: Int) async {
        do {
            let download = try await items[index].start()
            items[index].download = download
            let observer = Task { [weak self] in
                for await progress in download.progress { await self?.update(index, progress) }
            }
            let url = try await download.file()
            observer.cancel()
            items[index].result = .success(url)
            items[index].progress = download.currentProgress
        } catch {
            items[index].result = .failure(error)
        }
        running -= 1
        publish()
        pump()
        if running == 0, nextIndex == items.count {
            let waiters = self.waiters; self.waiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private func update(_ index: Int, _ progress: TransferProgress) {
        items[index].progress = progress
        publish()
    }

    private func snapshot() -> QueueProgress {
        let totals = items.compactMap(\.progress.totalBytes)
        return QueueProgress(
            completed: items.filter { if case .success = $0.result { true } else { false } }.count,
            failed: items.filter { if case .failure = $0.result { true } else { false } }.count,
            total: items.count,
            bytesTransferred: items.reduce(0) { $0 + $1.progress.bytesTransferred },
            totalBytes: totals.count == items.count ? totals.reduce(0, +) : nil)
    }

    private func publish() { progressContinuation?.yield(snapshot()) }

    private func waitUntilDone() async {
        guard !(running == 0 && nextIndex == items.count) else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
