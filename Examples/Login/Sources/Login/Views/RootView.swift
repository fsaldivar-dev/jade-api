import LoginCore
import SwiftUI

/// Selector de entorno a la izquierda con la sesión y el catálogo; registro de actividad a la derecha.
struct RootView: View {
    @Bindable var shell: AppShell

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                StagePicker(stage: $shell.stage)
                switch shell.state {
                case .ready(let container):
                    SessionPanel(session: container.session, catalog: container.catalog)
                case .failed(let message):
                    StartupErrorView(message: message)
                }
                Spacer()
            }
            .padding(20)
            .frame(minWidth: 380)

            ActivityLogView(log: shell.log)
                .frame(minWidth: 320)
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
        }
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}
