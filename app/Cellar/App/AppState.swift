import Foundation
import Combine

enum EngineStatus: Equatable {
    case idle
    case running
    case failed(String)
}

final class AppState: ObservableObject {
    @Published var containers: [Container] = Container.samples
    @Published var device: DeviceSnapshot = DeviceProbe.snapshot()
    @Published var engineStatus: EngineStatus = .idle

    func refreshDevice() {
        device = DeviceProbe.snapshot()
    }

    func update(_ container: Container) {
        guard let index = containers.firstIndex(where: { $0.id == container.id }) else { return }
        containers[index] = container
    }

    func delete(_ container: Container) {
        containers.removeAll { $0.id == container.id }
    }

    func add(name: String, gameTitle: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGame = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        containers.append(
            Container(
                name: trimmedName.isEmpty ? "Container mới" : trimmedName,
                gameTitle: trimmedGame.isEmpty ? "Chưa có game" : trimmedGame
            )
        )
    }
}
