import JadeAPI
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct LoginApp: App {
    @State private var model = SessionModel(stage: Stage.resolve(fallback: .mock))

    init() {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup("JadeAPI · Login") {
            LoginView(model: model).frame(minWidth: 720, minHeight: 460)
        }
    }
}

struct LoginView: View {
    @Bindable var model: SessionModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Entorno", selection: $model.stage) {
                    ForEach(Stage.allCases) { stage in Text(stage.rawValue).tag(stage) }
                }
                .pickerStyle(.segmented)
                Text(model.stage.baseURL.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)

                if let profile = model.profile {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(profile.name, systemImage: "person.crop.circle.fill").font(.title2)
                        Text("Rol: \(profile.role)").foregroundStyle(.secondary)
                        Button("Cerrar sesión") { Task { await model.logout() } }
                    }
                } else {
                    Form {
                        TextField("Usuario", text: $model.user)
                        SecureField("Contraseña", text: $model.password)
                    }
                    .formStyle(.grouped)
                    Button(model.busy ? "Entrando…" : "Entrar") { Task { await model.login() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                        .keyboardShortcut(.defaultAction)
                    Text("En mock: la contraseña es el mismo usuario (admin/admin, viewer/viewer). En dev y prod no hay servidor: verás el error de red tipado.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Spacer()
            }
            .padding(20)
            .frame(minWidth: 340)

            List(model.log, id: \.self) { line in Text(line).font(.caption.monospaced()) }
                .frame(minWidth: 300)
                .overlay(alignment: .top) {
                    Text("Decoradores: @Decorate(Logged(), Retry(2))").font(.caption).padding(4)
                }
        }
    }
}
