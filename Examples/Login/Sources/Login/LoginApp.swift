import LoginCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct LoginApp: App {
    @State private var shell = AppShell(stage: Stage.resolve(fallback: .mock))

    init() {
        #if os(macOS)
        // `swift run` lanza un ejecutable sin bundle: sin esto la ventana no toma el foco.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup("JadeAPI · Login") {
            RootView(shell: shell)
                .frame(minWidth: 760, minHeight: 480)
        }
    }
}
