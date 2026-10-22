/// Lo que el servidor del catálogo devuelve, tal cual. Nunca sale de la capa de red.
struct ProductDTO: Decodable {
    let id: Int
    let title: String
    let price_cents: Int
}

/// Body de error del servidor del catálogo.
struct APIErrorBody: Decodable {
    let code: String
    let message: String
}
