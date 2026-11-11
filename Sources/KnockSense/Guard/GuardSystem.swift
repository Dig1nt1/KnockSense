import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// macOS hooks used by Laptop Guard.
enum GuardSystem {
    /// Locks the screen immediately. Uses the same private call as the Lock Screen menu item,
    /// falling back to the ⌃⌘Q shortcut (needs Accessibility).
    static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
        } else {
            ActionRunner.run(.lockScreen)
        }
    }

    static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMACPowerKey
    }

    /// Seconds since any keyboard, trackpad or mouse activity (works on the lock screen too).
    static func secondsSinceAnyInput() -> Double {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .otherMouseDown]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }

    // MARK: Volume (AppleScript's standard volume commands; no permission needed)

    struct VolumeState {
        let level: Int
        let muted: Bool
    }

    static func currentVolume() -> VolumeState? {
        let output = runOSAScript("set s to get volume settings\nreturn (output volume of s as string) & \",\" & (output muted of s as string)")
        let parts = output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let level = Int(parts[0]) else { return nil }
        return VolumeState(level: level, muted: parts[1] == "true")
    }

    static func setVolume(_ state: VolumeState) {
        _ = runOSAScript("set volume output volume \(state.level) \(state.muted ? "with" : "without") output muted")
    }

    @discardableResult
    private static func runOSAScript(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Keeps the Mac from idle-sleeping while the guard is armed (closing the lid still sleeps it).
final class SleepBlocker {
    private var assertion: IOPMAssertionID = 0

    func start() {
        guard assertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "KnockSense Laptop Guard is armed" as CFString,
                                    &assertion)
    }

    func stop() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }
}
