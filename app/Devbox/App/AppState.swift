import Foundation
import Combine

enum EngineStatus: Equatable {
    case idle
    case booting
    case ready
    case failed(String)
}

final class AppState: ObservableObject {
    @Published var projects: [Project] = Project.samples
    @Published var device: DeviceSnapshot = DeviceProbe.snapshot()
    @Published var engineStatus: EngineStatus = .idle

    func refreshDevice() {
        device = DeviceProbe.snapshot()
    }

    func upsert(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
    }

    func touch(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].lastOpened = Date()
    }
}
