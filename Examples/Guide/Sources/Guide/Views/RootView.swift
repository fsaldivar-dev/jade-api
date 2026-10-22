import GuideCore
import SwiftUI

/// Selector de entorno arriba, una pestaña por pieza, y el registro de actividad a la derecha.
struct RootView: View {
    @Bindable var shell: AppShell

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                StagePicker(stage: $shell.stage)
                switch shell.state {
                case .ready(let container):
                    FeatureTabs(container: container, metrics: shell.metrics)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                }
            }
            .padding(16)
            .frame(minWidth: 520)

            ActivityLogView(log: shell.log)
                .frame(minWidth: 300)
        }
    }
}

private struct StagePicker: View {
    @Binding var stage: Stage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Entorno", selection: $stage) {
                ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(stage.servicesSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Cada pestaña recibe solo el store que necesita.
private struct FeatureTabs: View {
    let container: AppContainer
    let metrics: MetricsLog

    var body: some View {
        TabView {
            SessionView(session: container.session, catalog: container.catalog)
                .tabItem { Label("Sesión", systemImage: "person.crop.circle") }
            CatalogView(catalog: container.catalog, isSignedIn: container.session.isSignedIn)
                .tabItem { Label("Catálogo", systemImage: "bag") }
            StreamView(wiki: container.wiki)
                .tabItem { Label("Stream", systemImage: "dot.radiowaves.left.and.right") }
            DownloadsView(downloads: container.downloads)
                .tabItem { Label("Descargas", systemImage: "arrow.down.circle") }
            SocketView(echo: container.echo)
                .tabItem { Label("Socket", systemImage: "bolt.horizontal") }
            MetricsView(metrics: metrics)
                .tabItem { Label("Métricas", systemImage: "speedometer") }
        }
    }
}
