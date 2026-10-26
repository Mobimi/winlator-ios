import Foundation
import Combine

enum EngineStatus: Equatable {
    case idle
    case booting
    case ready
    case failed(String)
}

final class AppState: ObservableObject {
    @Published var projects: [Project] {
        didSet { saveProjects() }
    }
    @Published var device: DeviceSnapshot = DeviceProbe.snapshot()
    @Published var engineStatus: EngineStatus = .idle

    private let storeURL: URL
    private let projectsRoot: URL
    private var jitTimer: Timer?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = docs.appendingPathComponent("Projects.json")
        projectsRoot = docs.appendingPathComponent("Projects", isDirectory: true)

        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        } else {
            projects = Project.samples
        }

        for project in projects {
            ensureFolder(for: project)
        }
    }

    func refreshDevice() {
        device = DeviceProbe.snapshot()
        if device.jitReady {
            stopJITPolling()
        }
    }

    func startJITPolling() {
        refreshDevice()
        guard !device.jitReady, jitTimer == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshDevice()
        }
        RunLoop.main.add(timer, forMode: .common)
        jitTimer = timer
    }

    func stopJITPolling() {
        jitTimer?.invalidate()
        jitTimer = nil
    }

    func upsert(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        ensureFolder(for: project)
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
    }

    func touch(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].lastOpened = Date()
    }

    func folder(for project: Project) -> URL {
        projectsRoot.appendingPathComponent(project.slug, isDirectory: true)
    }

    private func ensureFolder(for project: Project) {
        try? FileManager.default.createDirectory(at: folder(for: project), withIntermediateDirectories: true)
    }

    private func saveProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
