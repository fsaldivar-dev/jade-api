import Foundation

/// Avance de una transferencia.
public struct TransferProgress: Sendable, Equatable {
    public var bytesTransferred: Int64
    /// `nil` cuando el servidor no informa el tamaño.
    public var totalBytes: Int64?

    public init(bytesTransferred: Int64, totalBytes: Int64?) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }

    public static let zero = TransferProgress(bytesTransferred: 0, totalBytes: nil)
}

/// Estado compartido entre el delegado de URLSession y el manejador. Un único consumidor por `progress`.
final class TransferState<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var progressValue = TransferProgress.zero
    private var progressContinuation: AsyncStream<TransferProgress>.Continuation?
    private var result: Result?
    private var error: (any Error)?
    private var waiters: [CheckedContinuation<Result, any Error>] = []
    let progress: AsyncStream<TransferProgress>

    init() {
        var continuation: AsyncStream<TransferProgress>.Continuation!
        progress = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        progressContinuation = continuation
    }

    var current: TransferProgress { lock.lock(); defer { lock.unlock() }; return progressValue }

    func report(_ progress: TransferProgress) {
        lock.lock(); progressValue = progress; let continuation = progressContinuation; lock.unlock()
        continuation?.yield(progress)
    }

    func finish(_ value: Result) {
        lock.lock()
        guard result == nil, error == nil else { lock.unlock(); return }
        result = value
        let waiters = self.waiters; self.waiters = []
        let continuation = progressContinuation; progressContinuation = nil
        lock.unlock()
        continuation?.finish()
        waiters.forEach { $0.resume(returning: value) }
    }

    func fail(_ failure: any Error) {
        lock.lock()
        guard result == nil, error == nil else { lock.unlock(); return }
        error = failure
        let waiters = self.waiters; self.waiters = []
        let continuation = progressContinuation; progressContinuation = nil
        lock.unlock()
        continuation?.finish()
        waiters.forEach { $0.resume(throwing: failure) }
    }

    func value() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result); return }
            if let error { lock.unlock(); continuation.resume(throwing: error); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Descarga en curso. Se obtiene de un endpoint `kind: .download`; la petición ya salió cuando lo tienes.
///
/// ```swift
/// let download = try await files.export(id: 7)
/// for await progress in download.progress { print(progress.fractionCompleted ?? 0) }
/// let url = try await download.file()
/// ```
public final class Download: Sendable {
    public let request: Request
    let state: TransferState<URL>
    private let controls: DownloadControls

    init(request: Request, controls: DownloadControls, state: TransferState<URL> = TransferState<URL>()) {
        self.request = request
        self.controls = controls
        self.state = state
    }

    /// Avance; el último valor se conserva para quien se suscriba tarde.
    public var progress: AsyncStream<TransferProgress> { state.progress }
    public var currentProgress: TransferProgress { state.current }

    /// Espera a que termine y devuelve el archivo final.
    public func file() async throws -> URL { try await state.value() }

    public func cancel() { controls.cancel() }

    /// Detiene la descarga conservando lo recibido. Devuelve los datos de reanudación si el servidor
    /// los soporta (`Accept-Ranges`); `nil` si no, en cuyo caso `resume()` empieza de cero.
    public func pause() async -> Data? { await controls.pause() }

    /// Continúa una descarga pausada.
    public func resume() { controls.resume() }
}

/// Operaciones que el transporte implementa para una descarga.
public struct DownloadControls: Sendable {
    public var cancel: @Sendable () -> Void
    public var pause: @Sendable () async -> Data?
    public var resume: @Sendable () -> Void

    public init(cancel: @escaping @Sendable () -> Void, pause: @escaping @Sendable () async -> Data?, resume: @escaping @Sendable () -> Void) {
        self.cancel = cancel
        self.pause = pause
        self.resume = resume
    }
}

/// Subida en curso. Se obtiene de un endpoint `kind: .upload`.
public final class Upload: Sendable {
    public let request: Request
    let state: TransferState<Response>
    private let cancelAction: @Sendable () -> Void

    init(request: Request, cancel: @escaping @Sendable () -> Void, state: TransferState<Response> = TransferState<Response>()) {
        self.request = request
        self.cancelAction = cancel
        self.state = state
    }

    public var progress: AsyncStream<TransferProgress> { state.progress }
    public var currentProgress: TransferProgress { state.current }

    /// Espera la respuesta del servidor (ya validada como 2xx).
    public func response() async throws -> Response { try await state.value() }

    /// Espera la respuesta y la decodifica.
    public func value<Out: Decodable>(_ type: Out.Type = Out.self, decoder: JSONDecoder = JSONDecoder()) async throws -> Out {
        let response = try await self.response()
        do { return try decoder.decode(Out.self, from: response.body) } catch { throw HTTPError.decoding(error, response) }
    }

    public func cancel() { cancelAction() }
}

/// Transporte capaz de transferencias con progreso. `URLSessionClient` y `MockClient` conforman.
public protocol TransferClient: HTTPClient {
    /// Inicia la descarga. `destination` es la ruta final; `nil` guarda en el directorio temporal.
    func download(_ request: Request, to destination: URL?) throws -> Download
    /// Inicia la subida del body ya codificado.
    func upload(_ request: Request, body: UploadBody) throws -> Upload
}

/// Lo que se sube.
public enum UploadBody: Sendable {
    case data(Data)
    case file(URL)
}

// MARK: - Archivos y multipart

/// Un archivo para subir. Úsalo como `Body<FileUpload>` en un endpoint `kind: .upload`.
public struct FileUpload: Sendable, Encodable {
    public var url: URL
    public var fieldName: String
    public var filename: String
    public var mimeType: String
    /// Campos de formulario que acompañan al archivo (multipart/form-data).
    public var fields: [String: String]

    public init(url: URL, fieldName: String = "file", filename: String? = nil, mimeType: String = "application/octet-stream", fields: [String: String] = [:]) {
        self.url = url
        self.fieldName = fieldName
        self.filename = filename ?? url.lastPathComponent
        self.mimeType = mimeType
        self.fields = fields
    }

    enum CodingKeys: CodingKey { case filename, mimeType, fields }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filename, forKey: .filename)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(fields, forKey: .fields)
    }
}

/// Cuerpo multipart/form-data. Las partes de archivo se leen al codificar.
public struct Multipart: Sendable, Encodable {
    public struct Part: Sendable {
        public var name: String
        public var filename: String?
        public var mimeType: String?
        public var content: Content
        public enum Content: Sendable { case text(String), data(Data), file(URL) }

        public static func field(_ name: String, _ value: String) -> Part { Part(name: name, filename: nil, mimeType: nil, content: .text(value)) }
        public static func file(_ name: String, url: URL, filename: String? = nil, mimeType: String = "application/octet-stream") -> Part {
            Part(name: name, filename: filename ?? url.lastPathComponent, mimeType: mimeType, content: .file(url))
        }
        public static func data(_ name: String, _ data: Data, filename: String, mimeType: String = "application/octet-stream") -> Part {
            Part(name: name, filename: filename, mimeType: mimeType, content: .data(data))
        }
    }

    public var parts: [Part]
    public var boundary: String

    public init(parts: [Part], boundary: String = "jade-" + UUID().uuidString) {
        self.parts = parts
        self.boundary = boundary
    }

    public init(_ file: FileUpload) {
        var parts = file.fields.sorted { $0.key < $1.key }.map { Part.field($0.key, $0.value) }
        parts.append(.file(file.fieldName, url: file.url, filename: file.filename, mimeType: file.mimeType))
        self.init(parts: parts)
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public func encoded() throws -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for part in parts {
            line("--\(boundary)")
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename { disposition += "; filename=\"\(filename)\"" }
            line(disposition)
            if let mimeType = part.mimeType { line("Content-Type: \(mimeType)") }
            line("")
            switch part.content {
            case .text(let text): body.append(Data(text.utf8))
            case .data(let data): body.append(data)
            case .file(let url): body.append(try Data(contentsOf: url))
            }
            line("")
        }
        line("--\(boundary)--")
        return body
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(parts.map(\.name))
    }
}


/// Para transportes propios: crea un ``Download`` o un ``Upload`` y reporta su avance y resultado.
public final class TransferStateBox<Result: Sendable>: Sendable {
    let state = TransferState<Result>()
    public init() {}

    public func report(_ progress: TransferProgress) { state.report(progress) }
    public func finish(_ value: Result) { state.finish(value) }
    public func fail(_ error: any Error) { state.fail(error) }
}

extension TransferStateBox where Result == URL {
    public func download(request: Request, controls: DownloadControls) -> Download {
        Download(request: request, controls: controls, state: state)
    }
}

extension TransferStateBox where Result == Response {
    public func upload(request: Request, cancel: @escaping @Sendable () -> Void) -> Upload {
        Upload(request: request, cancel: cancel, state: state)
    }
}
