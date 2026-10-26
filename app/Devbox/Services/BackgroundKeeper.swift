import AVFoundation
import Combine
import UIKit

final class BackgroundKeeper: ObservableObject {
    static let shared = BackgroundKeeper()

    @Published private(set) var isAudioRunning = false

    @Published private(set) var startedAt: Date?

    @Published private(set) var lastError: String?

    @Published private(set) var interruptionCount = 0

    @Published private(set) var backgroundTaskActive = false
    @Published private(set) var route = "—"
    @Published private(set) var category = "chưa cấu hình"
    @Published private(set) var otherAudioPlaying = false

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var wantsAudio = false
    private var configured = false

    private init() {
        installObservers()
        refreshSessionInfo()
    }

    var hasBackgroundAudioMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("audio") ?? false
    }

    var isKeepingAlive: Bool {
        isAudioRunning
    }

    var stateText: String {
        if isAudioRunning { return "Đang giữ nền" }
        if wantsAudio { return "Bật nhưng audio chưa chạy" }
        return "Tắt"
    }

    var uptimeText: String {
        guard let startedAt else { return "—" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours) giờ \(minutes) phút" }
        if minutes > 0 { return "\(minutes) phút" }
        return "\(seconds) giây"
    }

    func start() {
        wantsAudio = true
        guard !isAudioRunning else {
            refreshSessionInfo()
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            category = "playback · mixWithOthers"

            try prepareEngine()
            guard let buffer = silentBuffer else {
                throw KeeperError.noBuffer
            }

            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }

            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            player.play()

            isAudioRunning = true
            startedAt = startedAt ?? Date()
            lastError = nil
            endGraceTask()
        } catch {
            isAudioRunning = false
            lastError = message(for: error)
        }

        refreshSessionInfo()
    }

    func stop() {
        guard wantsAudio || isAudioRunning || taskID != .invalid else { return }
        wantsAudio = false
        player.stop()
        engine.stop()
        isAudioRunning = false
        startedAt = nil
        endGraceTask()

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            category = "đã tắt"
        } catch {
            lastError = message(for: error)
        }

        refreshSessionInfo()
    }

    func toggle() {
        if wantsAudio || isAudioRunning { stop() } else { start() }
    }

    func appBecameActive() {
        endGraceTask()
        refreshSessionInfo()
        if wantsAudio && !isAudioRunning {
            start()
        }
    }

    func appBecameInactive() {

        refreshSessionInfo()
    }

    func appDidEnterBackground() {
        guard wantsAudio else { return }
        start()
        if !isAudioRunning {

            beginGraceTask()
        }
        refreshSessionInfo()
    }

    private func prepareEngine() throws {
        guard !configured else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            throw KeeperError.noBuffer
        }

        buffer.frameLength = buffer.frameCapacity

        var seed: UInt32 = 0x9E37_79B9
        if let channels = buffer.floatChannelData {
            for index in 0..<Int(buffer.frameLength) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let value = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 1e-5
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][index] = value
                }
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        silentBuffer = buffer
        configured = true
    }

    private func rebuildEngine() {
        player.stop()
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        silentBuffer = nil
        configured = false
        isAudioRunning = false
        if wantsAudio {
            start()
        }
    }

    private func refreshSessionInfo() {
        let session = AVAudioSession.sharedInstance()
        otherAudioPlaying = session.isOtherAudioPlaying
        let output = session.currentRoute.outputs.first
        route = output.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "—"
        if isAudioRunning {
            category = "playback · mixWithOthers"
        }
    }

    private func beginGraceTask() {
        guard taskID == .invalid else { return }
        backgroundTaskActive = true
        taskID = UIApplication.shared.beginBackgroundTask(withName: "devbox.keepalive") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.backgroundTaskActive = false
                self.taskID = .invalid
                if self.wantsAudio && !self.isAudioRunning {
                    self.lastError = "iOS đã hết thời gian gia hạn nền và audio im lặng chưa chạy. App sẽ bị treo."
                }
            }
        }
    }

    private func endGraceTask() {
        guard taskID != .invalid else {
            backgroundTaskActive = false
            return
        }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
        backgroundTaskActive = false
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshSessionInfo()
            if self.wantsAudio && !self.isAudioRunning {
                self.start()
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.rebuildEngine()
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.wantsAudio else { return }
            if !self.isAudioRunning {
                self.start()
                if !self.isAudioRunning { self.beginGraceTask() }
            }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            interruptionCount += 1
            isAudioRunning = false

            if wantsAudio && UIApplication.shared.applicationState == .background {
                beginGraceTask()
            }
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if wantsAudio && (!isAudioRunning) {
                start()
            }
            if wantsAudio && !options.contains(.shouldResume) {

                start()
            }
        @unknown default:
            break
        }
        refreshSessionInfo()
    }

    private func message(for error: Error) -> String {
        if let keeper = error as? KeeperError {
            return keeper.text
        }
        return error.localizedDescription
    }

    private enum KeeperError: Error {
        case noBuffer

        var text: String {
            switch self {
            case .noBuffer:
                return "Không tạo được buffer audio im lặng."
            }
        }
    }
}
