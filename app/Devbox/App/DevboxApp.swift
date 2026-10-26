import SwiftUI

@main
struct DevboxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var keeper = BackgroundKeeper.shared
    @StateObject private var engine = QEMUEngine.shared

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("devbox.keepRunning") private var keepRunning = true

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    if keepRunning, engine.state.isActive { keeper.start() }
                    appState.startJITPolling()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                appState.refreshDevice()
                appState.startJITPolling()
                keeper.appBecameActive()
                GuestConsole.shared.appBecameActive()
            case .inactive:
                keeper.appBecameInactive()
            case .background:
                appState.stopJITPolling()
                keeper.appDidEnterBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: engine.state, initial: true) { _, state in
            // Audio im lặng chỉ có ích khi QEMU đang chạy. Để nó chạy lúc
            // engine nghỉ vừa tốn pin vừa hiện chỉ báo ghi âm vô ích.
            if keepRunning, state.isActive {
                keeper.start()
            } else {
                keeper.stop()
            }
        }
        .onChange(of: keepRunning) { _, enabled in
            if enabled, engine.state.isActive {
                keeper.start()
            } else {
                keeper.stop()
            }
        }
    }
}
