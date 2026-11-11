import Foundation

/// A spot on the Mac that the user has taught KnockSense to recognise (e.g. "Left palm rest").
public struct Zone: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Feature vectors recorded while training this zone.
    public var samples: [[Double]]
    /// Peak loudness of each training knock (may be shorter than `samples` for older configs).
    public var peaks: [Double]

    public init(id: UUID = UUID(), name: String, samples: [[Double]] = [], peaks: [Double] = []) {
        self.id = id
        self.name = name
        self.samples = samples
        self.peaks = peaks
    }

    enum CodingKeys: String, CodingKey { case id, name, samples, peaks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        samples = try c.decodeIfPresent([[Double]].self, forKey: .samples) ?? []
        peaks = try c.decodeIfPresent([Double].self, forKey: .peaks) ?? []
    }

    /// Training knocks as sound samples (peak 0 when unknown — ignored by the loudness check).
    public var soundSamples: [SoundSample] {
        samples.enumerated().map { i, f in SoundSample(features: f, peak: i < peaks.count ? Float(peaks[i]) : 0) }
    }
}

/// Ready-made actions that need no configuration.
public enum BuiltinAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case playPause, nextTrack, previousTrack
    case volumeUp, volumeDown, toggleMute
    case lockScreen, sleepDisplay, missionControl
    case screenshotToClipboard, screenshotAreaToClipboard, screenshot
    case notify

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playPause: return "Play / Pause media"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .toggleMute: return "Mute / Unmute"
        case .lockScreen: return "Lock screen"
        case .sleepDisplay: return "Sleep display"
        case .screenshotToClipboard: return "Screenshot to clipboard (whole screen)"
        case .screenshotAreaToClipboard: return "Screenshot area to clipboard (drag to select)"
        case .screenshot: return "Screenshot saved to Desktop"
        case .missionControl: return "Mission Control"
        case .notify: return "Show a notification (test)"
        }
    }
}

public enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtin, openApp, openURL, shell, appleScript, shortcut

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builtin: return "Built-in action"
        case .openApp: return "Open an app"
        case .openURL: return "Open a website or file"
        case .shell: return "Run a shell command"
        case .appleScript: return "Run AppleScript"
        case .shortcut: return "Run a Shortcut"
        }
    }

    public var placeholder: String {
        switch self {
        case .builtin: return ""
        case .openApp: return "/Applications/Safari.app or just Safari"
        case .openURL: return "https://example.com or ~/Documents/notes.txt"
        case .shell: return "say \"Hello\""
        case .appleScript: return "tell application \"Music\" to playpause"
        case .shortcut: return "Name of the Shortcut"
        }
    }
}

public struct KnockAction: Codable, Hashable, Sendable {
    public var kind: ActionKind
    /// Meaning depends on `kind`: builtin raw value, app path/name, URL, command, script or shortcut name.
    public var argument: String

    public init(kind: ActionKind, argument: String) {
        self.kind = kind
        self.argument = argument
    }

    public static func builtin(_ action: BuiltinAction) -> KnockAction {
        KnockAction(kind: .builtin, argument: action.rawValue)
    }

    public var isConfigured: Bool {
        switch kind {
        case .builtin: return BuiltinAction(rawValue: argument) != nil
        default: return !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var summary: String {
        let arg = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .builtin: return BuiltinAction(rawValue: arg)?.title ?? "Unknown action"
        case .openApp: return "Open " + URL(fileURLWithPath: arg).deletingPathExtension().lastPathComponent
        case .openURL: return "Open " + arg
        case .shell: return "Run: " + (arg.count > 40 ? String(arg.prefix(40)) + "…" : arg)
        case .appleScript: return "Run AppleScript"
        case .shortcut: return "Run Shortcut “\(arg)”"
        }
    }
}

/// "When I knock N times (on zone Z / anywhere), do this."
public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var knockCount: Int
    /// `nil` means "anywhere".
    public var zoneID: UUID?
    public var action: KnockAction

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, knockCount: Int,
                zoneID: UUID? = nil, action: KnockAction) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.knockCount = knockCount
        self.zoneID = zoneID
        self.action = action
    }
}

/// How KnockSense senses knocks.
public enum DetectionSource: String, Codable, CaseIterable, Sendable {
    /// Built-in microphones (works on every Mac).
    case microphone
    /// The MacBook's motion sensor via the root helper (Apple Silicon MacBook, M2 or newer).
    case motion
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var detectionSource: DetectionSource = .microphone
    /// 0 = only hard knocks, 1 = very light taps.
    public var sensitivity = 0.5
    /// Max seconds between knocks that belong to the same pattern.
    public var knockGap = 0.45
    public var playSound = true
    /// Ignore knocks right after keyboard / trackpad clicks (they sound like knocks too).
    public var ignoreWhileTyping = true
    /// Listen through the Mac's built-in mic even when AirPods / a headset are the default input.
    public var useBuiltInMic = true
    /// Look for new versions in the background and announce them in the menu.
    public var autoCheckUpdates = true
    /// Only react to sounds that resemble the user's trained knocks (once trained).
    public var verifyKnocks = true
    /// The knocks of a multi-knock pattern must sound alike (rejects door click + slam, etc.).
    public var requireConsistentPatterns = true
    /// "Teach my knock" samples and their peak loudness.
    public var knockSamples: [[Double]] = []
    public var knockPeaks: [Double] = []
    /// Sounds the user marked with "That wasn't me".
    public var rejectedSounds: [[Double]] = []
    public var guardSettings = GuardSettings()
    public var rules: [Rule] = []
    public var zones: [Zone] = []

    public init() {}

    /// Everything known about how the user knocks: "Teach my knock" plus all area training.
    public var trainedKnocks: [SoundSample] {
        let mine = knockSamples.enumerated().map { i, f in
            SoundSample(features: f, peak: i < knockPeaks.count ? Float(knockPeaks[i]) : 0)
        }
        return mine + zones.flatMap(\.soundSamples)
    }

    public static var defaults: AppConfig {
        var config = AppConfig()
        config.rules = [
            Rule(name: "Play / pause", knockCount: 2, action: .builtin(.playPause)),
            Rule(name: "Mission Control", knockCount: 3, action: .builtin(.missionControl)),
        ]
        return config
    }

    enum CodingKeys: String, CodingKey {
        case enabled, sensitivity, knockGap, playSound, ignoreWhileTyping, useBuiltInMic, autoCheckUpdates
        case detectionSource, verifyKnocks, requireConsistentPatterns, knockSamples, knockPeaks, rejectedSounds, guardSettings, rules, zones
    }

    // Tolerant decoding so older config files keep working when fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 0.5
        knockGap = try c.decodeIfPresent(Double.self, forKey: .knockGap) ?? 0.45
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? true
        ignoreWhileTyping = try c.decodeIfPresent(Bool.self, forKey: .ignoreWhileTyping) ?? true
        useBuiltInMic = try c.decodeIfPresent(Bool.self, forKey: .useBuiltInMic) ?? true
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        verifyKnocks = try c.decodeIfPresent(Bool.self, forKey: .verifyKnocks) ?? true
        detectionSource = (try? c.decodeIfPresent(DetectionSource.self, forKey: .detectionSource)) ?? .microphone
        requireConsistentPatterns = try c.decodeIfPresent(Bool.self, forKey: .requireConsistentPatterns) ?? true
        knockSamples = try c.decodeIfPresent([[Double]].self, forKey: .knockSamples) ?? []
        knockPeaks = try c.decodeIfPresent([Double].self, forKey: .knockPeaks) ?? []
        rejectedSounds = try c.decodeIfPresent([[Double]].self, forKey: .rejectedSounds) ?? []
        guardSettings = (try? c.decodeIfPresent(GuardSettings.self, forKey: .guardSettings)) ?? GuardSettings()
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        zones = try c.decodeIfPresent([Zone].self, forKey: .zones) ?? []
    }
}
