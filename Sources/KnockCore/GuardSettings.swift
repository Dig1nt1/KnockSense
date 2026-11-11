import Foundation

/// Laptop Guard preferences.
public struct GuardSettings: Codable, Equatable, Sendable {
    /// Lock the screen when arming; unlocking the Mac (Touch ID / password) disarms.
    public var lockScreen = true
    /// Seconds between a trigger and the alarm, so the owner can unlock first.
    public var graceSeconds = 5.0

    // Triggers
    public var watchMotion = true
    public var watchInput = true
    public var watchPower = true
    public var watchLid = true

    // Responses
    public var takePhotos = true
    public var soundAlarm = true
    public var maxVolume = true

    /// Push alerts to the phone via ntfy (https://ntfy.sh).
    public var phoneAlerts = false
    public var ntfyTopic = ""

    public init() {}

    /// A hard-to-guess ntfy topic name. Anyone who knows it can read the alerts, so it acts as a password.
    public static func randomTopic() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return "knocksense-" + String((0..<16).map { _ in alphabet.randomElement(using: &generator)! })
    }

    enum CodingKeys: String, CodingKey {
        case lockScreen, graceSeconds, watchMotion, watchInput, watchPower, watchLid
        case takePhotos, soundAlarm, maxVolume, phoneAlerts, ntfyTopic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuardSettings()
        lockScreen = try c.decodeIfPresent(Bool.self, forKey: .lockScreen) ?? d.lockScreen
        graceSeconds = try c.decodeIfPresent(Double.self, forKey: .graceSeconds) ?? d.graceSeconds
        watchMotion = try c.decodeIfPresent(Bool.self, forKey: .watchMotion) ?? d.watchMotion
        watchInput = try c.decodeIfPresent(Bool.self, forKey: .watchInput) ?? d.watchInput
        watchPower = try c.decodeIfPresent(Bool.self, forKey: .watchPower) ?? d.watchPower
        watchLid = try c.decodeIfPresent(Bool.self, forKey: .watchLid) ?? d.watchLid
        takePhotos = try c.decodeIfPresent(Bool.self, forKey: .takePhotos) ?? d.takePhotos
        soundAlarm = try c.decodeIfPresent(Bool.self, forKey: .soundAlarm) ?? d.soundAlarm
        maxVolume = try c.decodeIfPresent(Bool.self, forKey: .maxVolume) ?? d.maxVolume
        phoneAlerts = try c.decodeIfPresent(Bool.self, forKey: .phoneAlerts) ?? d.phoneAlerts
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? d.ntfyTopic
    }
}
