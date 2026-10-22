import GuideCore
import SwiftUI

/// Destacados y categorías (cargados a la vez con `all`), y el detalle de cada destacado desde un grupo
/// con límite de concurrencia. El producto 9999 no existe: su fila muestra el `CatalogError` tipado.
struct CatalogView: View {
    let catalog: CatalogStore
    let isSignedIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(catalog.isLoading ? "Cargando…" : "Cargar catálogo") { Task { await catalog.load() } }
                    .disabled(catalog.isLoading)
                Text("La primera carga en mock recibe un 503 y @Retries reintenta; la segunda sale de @CacheFor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !catalog.categories.isEmpty {
                Text("Categorías: " + catalog.categories.joined(separator: " · ")).font(.caption)
            }
            ForEach(catalog.featured) { product in
                HStack {
                    AsyncImage(url: product.thumbnail) { $0.resizable() } placeholder: { Color.gray.opacity(0.15) }
                        .frame(width: 32, height: 32)
                    Text(product.name)
                    Spacer()
                    Text(product.price, format: .currency(code: "USD")).monospacedDigit()
                }
            }
            if !catalog.details.isEmpty {
                Divider()
                Text("Detalles (groupSettled, máx. 2 a la vez):").font(.caption).foregroundStyle(.secondary)
                ForEach(catalog.sortedDetails, id: \.id) { entry in
                    DetailRow(id: entry.id, result: entry.result)
                }
            }
            if let error = catalog.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

private struct DetailRow: View {
    let id: Int
    let result: Result<Product, any Error>

    var body: some View {
        switch result {
        case .success(let product):
            Text("✓ \(id): \(product.name)").font(.caption)
        case .failure(let error):
            Text("✗ \(id): \(error)").font(.caption).foregroundStyle(.red)
        }
    }
}
