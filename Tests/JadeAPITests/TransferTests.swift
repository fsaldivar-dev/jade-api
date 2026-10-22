import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Fase 3b: descargas y subidas")
struct TransferTests {

    let mock = MockClient()
    var files: FilesRepository {
        FilesRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: mock,
                                                interceptors: [CommonHeaders(["X-App": "jade"])]))
    }

    @Test("Descarga: progreso hasta 1.0, archivo final con el contenido, adaptadores aplicados")
    func download() async throws {
        mock.on(.get, "/files/:id") { _ in MockResponse(body: Data(repeating: 7, count: 1000)) }
        mock.latency = .milliseconds(40)
        let download = try await files.export(id: 1)
        var fractions: [Double] = []
        for await progress in download.progress { if let f = progress.fractionCompleted { fractions.append(f) } }
        let url = try await download.file()
        #expect(fractions.last == 1.0)
        #expect(fractions == fractions.sorted())
        #expect(try Data(contentsOf: url).count == 1000)
        #expect(download.currentProgress.bytesTransferred == 1000)
        #expect(mock.received.first?.headers["X-App"] == "jade")
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Descarga con status de error falla en file() con HTTPError.status")
    func downloadError() async throws {
        mock.on(.get, "/files/:id") { _ in .status(404, body: "no existe") }
        let download = try await files.export(id: 9)
        do { _ = try await download.file(); Issue.record("debió fallar") }
        catch let error as HTTPError { #expect(error.statusCode == 404) }
    }

    @Test("Cancelar una descarga termina file() con HTTPError.cancelled")
    func downloadCancel() async throws {
        mock.on(.get, "/files/:id") { _ in MockResponse(body: Data(count: 10)) }
        mock.latency = .milliseconds(300)
        let download = try await files.export(id: 2)
        download.cancel()
        await #expect(throws: HTTPError.self) { try await download.file() }
    }

    @Test("Subida multipart: Content-Type con boundary, campos y archivo en el body, progreso y respuesta")
    func uploadMultipart() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jade-\(UUID().uuidString).txt")
        try Data("hola archivo".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        mock.on(.post, "/media") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            guard let type = request.headers["Content-Type"], type.hasPrefix("multipart/form-data; boundary=") else { return .status(400) }
            let boundary = type.replacingOccurrences(of: "multipart/form-data; boundary=", with: "")
            guard body.contains("--\(boundary)\r\n"), body.contains("name=\"album\"\r\n\r\nvacaciones"),
                  body.contains("name=\"file\"; filename=\"foto.txt\""), body.contains("Content-Type: text/plain"),
                  body.contains("hola archivo"), body.hasSuffix("--\(boundary)--\r\n") else { return .status(422, body: body) }
            return .json(#"{"id": 42}"#)
        }
        let upload = try await files.upload(file: Body(FileUpload(url: file, filename: "foto.txt", mimeType: "text/plain", fields: ["album": "vacaciones"])))
        var last: TransferProgress?
        for await progress in upload.progress { last = progress }
        #expect(last?.fractionCompleted == 1.0)
        struct Created: Decodable { let id: Int }
        #expect(try await upload.value(Created.self).id == 42)
    }

    @Test("Subida de Data cruda con PUT y octet-stream; un 500 falla en response()")
    func uploadRaw() async throws {
        mock.on(.put, "/media/raw") { request in
            request.headers["Content-Type"] == "application/octet-stream" && request.body?.count == 3 ? .noContent : .status(500)
        }
        let ok = try await files.uploadRaw(payload: Body(Data([1, 2, 3])))
        #expect(try await ok.response().status == 204)

        mock.reset()
        mock.on(.put, "/media/raw") { _ in .status(500) }
        let failing = try await files.uploadRaw(payload: Body(Data([1])))
        await #expect(throws: HTTPError.self) { try await failing.response() }
    }

    @Test("Un transporte sin transferencias lanza HTTPError.unsupported")
    func unsupported() async throws {
        struct Plain: HTTPClient { func send(_ request: Request) async throws -> Response { Response(status: 200, request: request) } }
        let repo: FilesRepository = FilesRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: Plain()))
        await #expect(throws: HTTPError.self) { _ = try await repo.export(id: 1) }
    }

    @Test("DownloadQueue: límite, progreso agregado y resultados en orden")
    func queue() async throws {
        mock.on(.get, "/files/:id") { request in MockResponse(body: Data(repeating: 1, count: 100 * (Int(request.path.split(separator: "/").last!) ?? 1))) }
        mock.latency = .milliseconds(30)
        let repo = files
        let queue = DownloadQueue(maxConcurrent: 2)
        for id in 1...4 { await queue.enqueue { try await repo.export(id: id) } }
        var seen: [QueueProgress] = []
        let observer = Task { for await progress in queue.progress { seen.append(progress); if progress.completed + progress.failed == 4 { break } } }
        let urls = try await queue.results()
        observer.cancel()
        #expect(urls.count == 4)
        #expect(try urls.map { try Data(contentsOf: $0).count } == [100, 200, 300, 400])
        #expect(await queue.summary.completed == 4)
        #expect(await queue.summary.bytesTransferred == 1000)
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    @Test("DownloadQueue.settled no lanza y conserva los errores por posición")
    func queueSettled() async throws {
        mock.on(.get, "/files/:id") { request in request.path == "/files/2" ? .status(500) : MockResponse(body: Data([0])) }
        let repo = files
        let queue = DownloadQueue(maxConcurrent: 3)
        for id in 1...3 { await queue.enqueue { try await repo.export(id: id) } }
        let results = await queue.settled()
        #expect((try? results[0].get()) != nil)
        #expect((try? results[1].get()) == nil)
        #expect((try? results[2].get()) != nil)
        #expect(await queue.summary.failed == 1)
    }
}
