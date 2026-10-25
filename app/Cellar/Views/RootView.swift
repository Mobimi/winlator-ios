import SwiftUI

struct RootView: View {
    enum Tab {
        case library
        case setup
    }

    @State private var tab: Tab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Thư viện", systemImage: "square.grid.2x2") }
                .tag(Tab.library)

            SetupView()
                .tabItem { Label("Thiết lập", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.setup)
        }
        .tint(.green)
    }
}
