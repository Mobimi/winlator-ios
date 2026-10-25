import SwiftUI

struct RootView: View {
    enum Tab {
        case projects
        case setup
    }

    @State private var tab: Tab = .projects

    var body: some View {
        TabView(selection: $tab) {
            ProjectsView()
                .tabItem { Label("Dự án", systemImage: "folder") }
                .tag(Tab.projects)

            SetupView()
                .tabItem { Label("Thiết lập", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.setup)
        }
        .tint(.green)
    }
}
