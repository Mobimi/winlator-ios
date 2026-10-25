import Foundation
import Combine
import GameController

final class GamepadMonitor: ObservableObject {
    @Published private(set) var controllers: [String] = []
    @Published private(set) var lastEvent: String = "chưa có"

    private var cancellables = Set<AnyCancellable>()

    init() {
        refresh()

        NotificationCenter.default
            .publisher(for: .GCControllerDidConnect)
            .merge(with: NotificationCenter.default.publisher(for: .GCControllerDidDisconnect))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        let connected = GCController.controllers()
        controllers = connected.map { controller in
            let name = controller.vendorName ?? "Tay cầm"
            return "\(name) — \(controller.productCategory)"
        }
        attachHandlers()
    }

    func startDiscovery() {
        GCController.startWirelessControllerDiscovery(completionHandler: {})
    }

    private func attachHandlers() {
        guard let pad = GCController.controllers().first?.extendedGamepad else { return }

        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async {
                self?.lastEvent = pressed ? "A ↓" : "A ↑"
            }
        }

        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            DispatchQueue.main.async {
                self?.lastEvent = String(format: "L %.2f / %.2f", Double(x), Double(y))
            }
        }
    }
}
