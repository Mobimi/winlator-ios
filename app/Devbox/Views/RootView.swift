import SwiftUI

struct RootView: View {
    enum Tab {
        case projects
        case shell
        case setup
    }

    @State private var tab: Tab = .projects

    var body: some View {
        TabView(selection: $tab) {
            ProjectsView()
                .tabItem { Label("Dự án", systemImage: "folder") }
                .tag(Tab.projects)

            ShellView()
                .tabItem { Label("Shell", systemImage: "terminal") }
                .tag(Tab.shell)

            SetupView()
                .tabItem { Label("Thiết lập", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.setup)
        }
        .tint(.green)
    }
}
