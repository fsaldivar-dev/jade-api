import Foundation
import JadeAPI
import Testing

@Suite("Transformadores")
struct TransformerTests {

    let mock = MockClient()
    var profiles: ProfilesRepository {
        ProfilesRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: mock))
    }

    @Test("@Unwrap del protocolo + @Transform: {data: DTO} → dominio")
    func unwrapAndTransform() async throws {
        mock.on(.get, "/profiles/:id") { _ in .json(#"{"data": {"id": 7, "full_name": "Paco Saldívar"}, "meta": {}}"#) }
        #expect(try await profiles.profile(id: 7) == Profile(id: 7, name: "Paco Saldívar"))
    }

    @Test("@Unwrap del requisito gana y admite ruta de claves")
    func unwrapKeyPath() async throws {
        mock.on(.get, "/profiles") { _ in .json(#"{"data": {"items": [{"id": 1, "full_name": "A"}, {"id": 2, "full_name": "B"}]}}"#) }
        #expect(try await profiles.all().map(\.id) == [1, 2])
    }

    @Test("@Unwrap y @Transform en el mismo requisito")
    func both() async throws {
        mock.on(.get, "/profiles/:id/alt") { _ in .json(#"{"result": {"id": 3, "full_name": "C"}}"#) }
        #expect(try await profiles.alternative(id: 3).name == "C")
    }

    @Test("@ErrorTransform: el body de un 4xx se convierte en error de dominio")
    func errorTransform() async throws {
        mock.on(.get, "/profiles/:id") { _ in .json(#"{"data": {"code": "NOT_FOUND", "message": "no existe"}}"#, status: 404) }
        await #expect(throws: DomainError.api(code: "NOT_FOUND", message: "no existe")) { try await profiles.profile(id: 404) }
    }

    @Test("@ErrorTransform: si el body no decodifica, sube el HTTPError original")
    func errorTransformFallback() async throws {
        mock.on(.get, "/profiles/:id") { _ in .status(500, body: "boom") }
        do { _ = try await profiles.profile(id: 1); Issue.record("debió lanzar") }
        catch let error as HTTPError { #expect(error.statusCode == 500) }
    }

    @Test("Clave ausente en el envelope: HTTPError.decoding con la respuesta")
    func missingKey() async throws {
        mock.on(.get, "/profiles/:id") { _ in .json(#"{"other": 1}"#) }
        do { _ = try await profiles.profile(id: 1); Issue.record("debió lanzar") }
        catch let error as HTTPError {
            guard case .decoding(_, let response) = error else { Issue.record("esperaba .decoding"); return }
            #expect(response.status == 200)
        }
    }
}
