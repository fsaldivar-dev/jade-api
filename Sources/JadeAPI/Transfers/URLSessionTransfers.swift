import Foundation

// MARK: - URLSessionClient: descargas y subidas con delegado por tarea (iOS 15+, macOS 12+)

extension URLSessionClient: TransferClient {

    public func download(_ request: Request, to destination: URL?) throws -> Download {
        let target = destination ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("jade-\(UUID().uuidString)")
            .appendingPathExtension(request.url.pathExtension.isEmpty ? "download" : request.url.pathExtension)
        let coordinator = DownloadCoordinator(session: session, request: request, destination: target)
        let download = Download(request: request, controls: DownloadControls(
            cancel: { coordinator.cancel() },
            pause: { await coordinator.pause() },
            resume: { coordinator.resume() }))
        coordinator.attach(download.state)
        coordinator.start()
        return download
    }

    public func upload(_ request: Request, body: UploadBody) throws -> Upload {
        let delegate = UploadDelegate(request: request)
        let task: URLSessionUploadTask
        switch body {
        case .data(let data): task = session.uploadTask(with: request.urlRequest, from: data)
        case .file(let url): task = session.uploadTask(with: request.urlRequest, fromFile: url)
        }
        task.delegate = delegate
        let upload = Upload(request: request) { task.cancel() }
        delegate.state = upload.state
        task.resume()
        return upload
    }
}

/// Lleva la tarea de descarga, su delegado y la reanudación.
final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let session: URLSession
    private let request: Request
    private let destination: URL
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var state: TransferState<URL>?
    private var pausing: CheckedContinuation<Data?, Never>?

    init(session: URLSession, request: Request, destination: URL) {
        self.session = session
        self.request = request
        self.destination = destination
    }

    func attach(_ state: TransferState<URL>) { self.state = state }

    func start() {
        let task = session.downloadTask(with: request.urlRequest)
        task.delegate = self
        lock.lock(); self.task = task; lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock(); let task = self.task; lock.unlock()
        task?.cancel()
    }

    private func currentTask() -> URLSessionDownloadTask? { lock.lock(); defer { lock.unlock() }; return task }
    private func storedResumeData() -> Data? { lock.lock(); defer { lock.unlock() }; return resumeData }
    private func setPausing(_ continuation: CheckedContinuation<Data?, Never>) { lock.lock(); pausing = continuation; lock.unlock() }

    func pause() async -> Data? {
        guard let task = currentTask() else { return storedResumeData() }
        return await withCheckedContinuation { continuation in
            setPausing(continuation)
            task.cancel { [weak self] data in
                guard let self else { return }
                self.lock.lock()
                self.resumeData = data
                let continuation = self.pausing; self.pausing = nil
                self.lock.unlock()
                continuation?.resume(returning: data)
            }
        }
    }

    func resume() {
        lock.lock(); let data = resumeData; resumeData = nil; lock.unlock()
        let task = data.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request.urlRequest)
        task.delegate = self
        lock.lock(); self.task = task; lock.unlock()
        task.resume()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        state?.report(TransferProgress(bytesTransferred: totalBytesWritten, totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // El archivo temporal desaparece al salir de este método: moverlo aquí, de forma síncrona.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = (try? Data(contentsOf: location)) ?? Data()
                state?.fail(HTTPError.status(http.statusCode, Response(status: http.statusCode, headers: [:], body: body, request: request)))
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            state?.finish(destination)
        } catch {
            state?.fail(HTTPError.transport(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }   // el éxito ya se reportó en didFinishDownloadingTo
        lock.lock(); let isPausing = pausing != nil || resumeData != nil; lock.unlock()
        if isPausing { return }           // cancelación controlada por pause()
        if let urlError = error as? URLError, urlError.code == .cancelled { state?.fail(HTTPError.cancelled); return }
        state?.fail(HTTPError.transport(error))
    }
}

final class UploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: Request
    private let lock = NSLock()
    private var received = Data()
    var state: TransferState<Response>?

    init(request: Request) { self.request = request }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        state?.report(TransferProgress(bytesTransferred: totalBytesSent, totalBytes: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); received.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled { state?.fail(HTTPError.cancelled) } else { state?.fail(HTTPError.transport(error)) }
            return
        }
        guard let http = task.response as? HTTPURLResponse else { state?.fail(HTTPError.transport(URLError(.badServerResponse))); return }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields { if let name = name as? String, let value = value as? String { headers[name] = value } }
        lock.lock(); let body = received; lock.unlock()
        let response = Response(status: http.statusCode, headers: headers, body: body, request: request)
        if response.isSuccess { state?.finish(response) } else { state?.fail(HTTPError.status(response.status, response)) }
    }
}
