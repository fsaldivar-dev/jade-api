import JadeAPI

/// Servicio `photos` (picsum.photos): fotos reales de unos 30 a 300 KB.
///
/// `kind: .download` devuelve un `Download` con progreso y el archivo final; `DownloadQueue` los
/// encola con un límite de descargas simultáneas (ver `DownloadsStore`).
@Repository(service: "photos")
public protocol PhotosRepository: Sendable {
    /// GET /seed/:seed/800/500 → siempre la misma foto para la misma semilla.
    @Api("/seed/:seed/800/500", kind: .download)
    func photo(seed: String) async throws -> Download
}
