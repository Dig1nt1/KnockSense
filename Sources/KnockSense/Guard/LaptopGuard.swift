import AppKit
import CoreAudio
import Foundation
import KnockCore
import LocalAuthentication

/// Laptop Guard: arm it when leaving the Mac. If it is moved, touched, unplugged or its lid is
/// closed, it takes a webcam photo, then (after a short grace period for the owner to unlock)
/// sounds a siren at full volume and pushes an alert with the photo to the owner's phone.
/// Unlocking the Mac (or Touch ID in KnockSense) disarms it.
@MainActor
final class LaptopGuard: ObservableObject {
    enum Phase: Equatable {
        case off
        case arming(secondsLeft: Int)
        case armed
        case triggered(reason: String, secondsLeft: Int)
        case alarm(reason: String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var lastPhoto: URL?
    @Published private(set) var testAlertResult: String?

    // Wired up by AppState.
    var settings: () -> GuardSettings = { GuardSettings() }
    var log: (String) -> Void = { _ in }
    /// Start/stop watching the motion sensor for movement.
    var setMotionWatch: (Bool) -> Void = { _ in }

    static let armingDelay = 10

    private let camera = GuardCamera()
    private let siren = Siren()
    private let sleepBlocker = SleepBlocker()
    private var countdownTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var alarmTasks: [Task<Void, Never>] = []
    private var firstPhoto: Task<Data?, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var armedAt = Date()
    private var armedOnAC = false
    private var lidClosedWhileArmed = false
    /// Photo grabbed the instant the lid started closing (sent once the Mac wakes up).
    private var lidPhoto: Data?
    private var savedVolume: GuardSystem.VolumeState?
    private var savedOutputDevice: AudioDeviceID?
    private var phoneAlerted = false

    var isActive: Bool { phase != .off }

    var isAlarming: Bool {
        switch phase {
        case .triggered, .alarm: return true
        default: return false
        }
    }

    // MARK: - Arming

    func arm() {
        guard phase == .off else { return }
        let s = settings()
        Task { @MainActor in
            if s.takePhotos && !GuardCamera.authorized {
                _ = await GuardCamera.requestAccess()
            }
            self.phase = .arming(secondsLeft: Self.armingDelay)
            self.countdownTask = Task { @MainActor [weak self] in
                for left in stride(from: Self.armingDelay, to: 0, by: -1) {
                    self?.phase = .arming(secondsLeft: left)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self?.activate()
            }
        }
    }

    /// Cancels arming, or disarms without authentication (used after the Mac was unlocked).
    func disarm(_ how: String) {
        guard phase != .off else { return }
        let wasAlarming = isAlarming
        countdownTask?.cancel()
        monitorTask?.cancel()
        alarmTasks.forEach { $0.cancel() }
        alarmTasks = []
        firstPhoto = nil
        siren.stop()
        camera.stop()
        sleepBlocker.stop()
        setMotionWatch(false)
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        restoreAudio()
        lidClosedWhileArmed = false
        lidPhoto = nil
        phase = .off
        log("Laptop Guard off (\(how))")
        GuardOverlay.shared.hide()
        let s = settings()
        if wasAlarming && phoneAlerted && s.phoneAlerts {
            let topic = s.ntfyTopic
            Task { _ = await PhoneAlert.send(topic: topic, title: "Laptop Guard disarmed",
                                             message: "Your Mac was unlocked and the alarm stopped.",
                                             priority: "default", tags: "white_check_mark") }
        }
        phoneAlerted = false
    }

    /// Disarm from inside KnockSense: requires Touch ID or the Mac password (unless only arming).
    func requestDisarm() {
        if case .arming = phase {
            disarm("cancelled")
            return
        }
        let context = LAContext()
        Task { @MainActor in
            do {
                if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "turn off Laptop Guard") {
                    self.disarm("unlocked with Touch ID / password")
                }
            } catch {
                // Cancelled or failed: stay armed.
            }
        }
    }

    private func activate() {
        let s = settings()
        armedAt = Date()
        armedOnAC = GuardSystem.isOnACPower()
        lidClosedWhileArmed = false
        phoneAlerted = false
        sleepBlocker.start()
        if s.watchMotion { setMotionWatch(true) }
        if s.takePhotos && s.keepCameraReady { camera.start() }

        // Unlocking the Mac proves it's the owner.
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.disarm("Mac unlocked") }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.macWillSleep() }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.macDidWake() }
        }))

        phase = .armed
        log("Laptop Guard armed")
        if s.lockScreen {
            GuardSystem.lockScreen()
        } else {
            GuardOverlay.shared.show(guardian: self)
        }

        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.checkTriggers()
            }
        }
    }

    // MARK: - Triggers

    private func checkTriggers() {
        guard phase == .armed else { return }
        let s = settings()
        let sinceArmed = Date().timeIntervalSince(armedAt)
        guard sinceArmed > 2 else { return }      // let the lock screen settle
        if s.watchInput && GuardSystem.secondsSinceAnyInput() < sinceArmed - 1 {
            trigger("Someone used the keyboard or trackpad")
        } else if s.watchPower && armedOnAC && !GuardSystem.isOnACPower() {
            trigger("The charger was unplugged")
        }
    }

    /// Called by the motion sensor when the Mac is lifted, tilted or carried.
    func motionDetected(_ description: String) {
        guard settings().watchMotion else { return }
        trigger(description)
    }

    private func macWillSleep() {
        guard isActive, phase != .off else { return }
        if case .arming = phase { return }
        let s = settings()
        guard s.watchLid else { return }
        lidClosedWhileArmed = true
        siren.stop()
        if s.takePhotos {
            // Grab the frame from just before the lid went down, before the Mac falls asleep.
            Task { @MainActor [weak self] in
                guard let self, let data = await self.camera.photo(secondsAgo: 0.3) else { return }
                self.lidPhoto = data
                if let url = GuardCamera.save(data, label: "lid closing") { self.lastPhoto = url }
            }
        }
        if s.phoneAlerts {
            let topic = s.ntfyTopic
            Task { _ = await PhoneAlert.send(topic: topic, title: "Laptop Guard: lid closed",
                                             message: "Someone closed your Mac's lid while the guard was armed.") }
        }
    }

    private func macDidWake() {
        guard isActive else { return }
        let s = settings()
        if s.takePhotos && s.keepCameraReady { camera.start() }   // sleep stops the camera
        if case .alarm = phase {
            siren.start()          // keep screaming after a lid close / reopen
            return
        }
        if lidClosedWhileArmed && s.watchLid {
            lidClosedWhileArmed = false
            trigger("The lid was closed and opened again")
        }
    }

    func trigger(_ reason: String) {
        guard phase == .armed else { return }
        let s = settings()
        log("Laptop Guard triggered: \(reason)")
        if s.takePhotos {
            let lid = lidPhoto
            lidPhoto = nil
            // Instant shot from just before the trigger (warm camera), then one more a moment later
            // when the person is likely looking at the screen.
            firstPhoto = Task { @MainActor [weak self] in
                if let lid { return lid }
                return await self?.takePhoto(secondsAgo: 0.4)
            }
            alarmTasks.append(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, self.isAlarming else { return }
                _ = await self.takePhoto()
            })
        }
        GuardOverlay.shared.show(guardian: self)
        let grace = max(0, Int(s.graceSeconds.rounded()))
        if grace == 0 {
            startAlarm(reason)
            return
        }
        phase = .triggered(reason: reason, secondsLeft: grace)
        countdownTask = Task { @MainActor [weak self] in
            for left in stride(from: grace, to: 0, by: -1) {
                self?.phase = .triggered(reason: reason, secondsLeft: left)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            self?.startAlarm(reason)
        }
    }

    // MARK: - Alarm

    private func startAlarm(_ reason: String) {
        let s = settings()
        phase = .alarm(reason: reason)
        log("Laptop Guard ALARM: \(reason)")

        if s.soundAlarm {
            if s.maxVolume { forceLoudSpeakers() }
            siren.start()
            if s.maxVolume {
                // Keep the volume up even if someone turns it down.
                alarmTasks.append(Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self, case .alarm = self.phase else { return }
                        GuardSystem.setVolume(.init(level: 100, muted: false))
                    }
                })
            }
        }

        if s.phoneAlerts {
            let topic = s.ntfyTopic
            let photoTask = firstPhoto
            alarmTasks.append(Task { @MainActor [weak self] in
                let photo = await photoTask?.value
                let error = await PhoneAlert.send(topic: topic, title: "Laptop Guard ALARM",
                                                  message: "\(reason). The alarm is sounding on your Mac.", photo: photo)
                self?.phoneAlerted = error == nil
                self?.log(error.map { "Phone alert failed: \($0)" } ?? "Phone alert sent")
            })
        }

        if s.takePhotos {
            // A few more photos while the alarm runs.
            alarmTasks.append(Task { @MainActor [weak self] in
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard let self, case .alarm = self.phase else { return }
                    _ = await self.takePhoto()
                }
            })
        }
    }

    @discardableResult
    private func takePhoto(secondsAgo: Double = 0) async -> Data? {
        guard let data = await camera.photo(secondsAgo: secondsAgo) else { return nil }
        if let url = GuardCamera.save(data) {
            lastPhoto = url
            log("Guard photo saved: \(url.lastPathComponent)")
        }
        return data
    }

    /// Full volume through the Mac's own speakers (not AirPods / headphones).
    private func forceLoudSpeakers() {
        if savedVolume == nil { savedVolume = GuardSystem.currentVolume() }
        if let speakers = AudioDevices.builtInSpeakers(), let current = AudioDevices.defaultOutputDevice(), current != speakers {
            savedOutputDevice = current
            AudioDevices.setDefaultOutputDevice(speakers)
        }
        GuardSystem.setVolume(.init(level: 100, muted: false))
    }

    private func restoreAudio() {
        if let device = savedOutputDevice {
            AudioDevices.setDefaultOutputDevice(device)
            savedOutputDevice = nil
        }
        if let volume = savedVolume {
            GuardSystem.setVolume(volume)
            savedVolume = nil
        }
    }

    // MARK: - Phone alert test

    func sendTestAlert() {
        let topic = settings().ntfyTopic
        testAlertResult = "Sending…"
        Task { @MainActor in
            let error = await PhoneAlert.send(topic: topic, title: "KnockSense test alert",
                                              message: "Phone alerts work. This is how Laptop Guard will reach you.",
                                              priority: "high", tags: "shield")
            self.testAlertResult = error ?? "Sent! Check your phone."
        }
    }
}
