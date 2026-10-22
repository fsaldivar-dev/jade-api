import Foundation

extension URLSessionClient: SocketClient {
    public func connect(_ request: Request) async throws -> any SocketConnection {
        let task = session.webSocketTask(with: request.urlRequest)
        let connection = URLSessionSocketConnection(task: task)
        task.delegate = connection
        task.resume()
        try await connection.waitUntilOpen()
        return connection
    }
}

/// Envuelve `URLSessionWebSocketTask` y espera el handshake con un delegado por tarea.
final class URLSessionSocketConnection: NSObject, SocketConnection, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var opened = false
    private var openError: (any Error)?
    private var openWaiters: [CheckedContinuation<Void, any Error>] = []

    init(task: URLSessionWebSocketTask) { self.task = task }

    func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if opened { lock.unlock(); continuation.resume(); return }
            if let openError { lock.unlock(); continuation.resume(throwing: openError); return }
            openWaiters.append(continuation)
            lock.unlock()
        }
    }

    func send(_ frame: SocketFrame) async throws {
        switch frame {
        case .text(let text): try await task.send(.string(text))
        case .binary(let data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> SocketFrame {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: throw HTTPError.transport(URLError(.badServerResponse))
            }
        } catch {
            if task.closeCode != .invalid {
                throw SocketClosed(code: task.closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) })
            }
            throw error
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close(code: Int, reason: String?) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: reason.map { Data($0.utf8) })
    }

    // MARK: Delegado

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock(); opened = true; let waiters = openWaiters; openWaiters = []; lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard !opened else { lock.unlock(); return }
        let failure: HTTPError
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 101 {
            // El servidor contestó el handshake con un status (401, 403, 503…): se distingue de una caída de red.
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields { if let name = name as? String, let value = value as? String { headers[name] = value } }
            let original = task.originalRequest
            let request = Request(method: .get, url: original?.url ?? http.url ?? URL(string: "ws://invalid")!, path: original?.url?.path ?? "", headers: original?.allHTTPHeaderFields ?? [:])
            failure = .status(http.statusCode, Response(status: http.statusCode, headers: headers, request: request))
        } else {
            failure = error.map { HTTPError.transport($0) } ?? HTTPError.transport(URLError(.badServerResponse))
        }
        openError = failure
        let waiters = openWaiters; openWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(throwing: failure) }
    }
}
