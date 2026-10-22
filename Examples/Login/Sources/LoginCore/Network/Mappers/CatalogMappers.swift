import Foundation
import JadeAPI

/// DTO → dominio. El compilador verifica que `Input` es lo que se decodifica y `Output` el retorno del endpoint.
struct ProductMapper: Transformer {
    func transform(_ dto: ProductDTO) throws -> Product {
        Product(id: dto.id, name: dto.title, price: Decimal(dto.price_cents) / 100)
    }
}

struct ProductsMapper: Transformer {
    func transform(_ dtos: [ProductDTO]) throws -> [Product] {
        try dtos.map(ProductMapper().transform)
    }
}

/// Body de error → `CatalogError`. Lo aplica `@ErrorTransform` a todo el repositorio del catálogo.
struct CatalogErrorMapper: Transformer {
    func transform(_ body: APIErrorBody) throws -> CatalogError {
        .api(code: body.code, message: body.message)
    }
}
