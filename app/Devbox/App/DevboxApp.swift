import SwiftUI

@main
struct DevboxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var keeper = BackgroundKeeper.shared

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("devbox.keepRunning") private var keepRunning = true

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    if keepRunning { keeper.start() }
                    appState.startJITPolling()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                appState.refreshDevice()
                appState.startJITPolling()
                keeper.appBecameActive()
            case .inactive:
                keeper.appBecameInactive()
            case .background:
                appState.stopJITPolling()
                keeper.appDidEnterBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: keepRunning) { _, enabled in
            if enabled {
                keeper.start()
            } else {
                keeper.stop()
            }
        }
    }
}
