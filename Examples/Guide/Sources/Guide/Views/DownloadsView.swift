import GuideCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Cinco fotos en una `DownloadQueue` con dos a la vez: barra de progreso agregada y cada archivo al terminar.
struct DownloadsView: View {
    let downloads: DownloadsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(downloads.isRunning ? "Descargando…" : "Descargar 5 fotos") { Task { await downloads.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloads.isRunning)
                Button("Limpiar") { downloads.clear() }.disabled(downloads.isRunning || downloads.items.isEmpty)
            }
            Text("kind: .download → Download con progreso; DownloadQueue(maxConcurrent: 2) y queue.settled(). En live es picsum.photos.")
                .font(.footnote).foregroundStyle(.secondary)
            if downloads.progress.total > 0 {
                ProgressView(value: downloads.progress.fractionCompleted)
                Text("\(downloads.progress.completed) de \(downloads.progress.total) · \(downloads.progress.failed) fallidas · \(downloads.progress.bytesTransferred / 1024) KB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(downloads.items) { item in
                        VStack {
                            PhotoThumbnail(file: item.file)
                            Text(item.seed).font(.caption)
                            if let error = item.error { Text(error).font(.caption2).foregroundStyle(.red) }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

/// La foto si el archivo es una imagen; si no (mock), el tamaño del archivo.
private struct PhotoThumbnail: View {
    let file: URL?

    var body: some View {
        Group {
            #if os(macOS)
            if let file, let image = NSImage(contentsOf: file) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let file, let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int {
                Text("\(size / 1024) KB").font(.caption)
            } else {
                ProgressView()
            }
            #else
            ProgressView()
            #endif
        }
        .frame(width: 120, height: 75)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
