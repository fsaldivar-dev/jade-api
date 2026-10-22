/// Lo que devuelve `GET /products/:id` de dummyjson.com, tal cual. Nunca sale de la capa de red.
struct ProductDTO: Decodable {
    let id: Int
    let title: String
    let price: Double
    let thumbnail: String
}

/// Body de error de dummyjson: `{"message": "Product with id '99' not found"}`.
struct APIErrorBody: Decodable {
    let message: String
}
