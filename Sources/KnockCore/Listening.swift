import Foundation

// MARK: - Settings

/// Preferences for the "Someone's calling you" alert and auto-duck.
public struct ListenSettings: Codable, Equatable, Sendable {
    // "Someone's calling you"
    public var nameAlertEnabled = false
    /// Names and nicknames, comma separated (e.g. "Diganta, Dig").
    public var names = ""
    /// Speech recognition language ("" = the Mac's language).
    public var localeID = ""
    public var pauseMusicOnName = true

    // Auto-duck
    public var autoDuckEnabled = false
    /// Volume while someone is talking, as a fraction of the current volume.
    public var duckLevel = 0.3
    /// 0 = only loud, close-up voices … 1 = quieter voices too.
    public var duckSensitivity = 0.5
    public var pauseDuckingDuringCalls = true

    /// Both features only act while headphones are in use (through speakers the Mac hears itself).
    public var headphonesOnly = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case nameAlertEnabled, names, localeID, pauseMusicOnName
        case autoDuckEnabled, duckLevel, duckSensitivity, pauseDuckingDuringCalls, headphonesOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ListenSettings()
        nameAlertEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .nameAlertEnabled)) ?? d.nameAlertEnabled
        names = (try? c.decodeIfPresent(String.self, forKey: .names)) ?? d.names
        localeID = (try? c.decodeIfPresent(String.self, forKey: .localeID)) ?? d.localeID
        pauseMusicOnName = (try? c.decodeIfPresent(Bool.self, forKey: .pauseMusicOnName)) ?? d.pauseMusicOnName
        autoDuckEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autoDuckEnabled)) ?? d.autoDuckEnabled
        duckLevel = (try? c.decodeIfPresent(Double.self, forKey: .duckLevel)) ?? d.duckLevel
        duckSensitivity = (try? c.decodeIfPresent(Double.self, forKey: .duckSensitivity)) ?? d.duckSensitivity
        pauseDuckingDuringCalls = (try? c.decodeIfPresent(Bool.self, forKey: .pauseDuckingDuringCalls)) ?? d.pauseDuckingDuringCalls
        headphonesOnly = (try? c.decodeIfPresent(Bool.self, forKey: .headphonesOnly)) ?? d.headphonesOnly
    }

    public var nameList: [String] { NameMatcher.parseNames(names) }
}

// MARK: - Name matching

/// Finds the user's names in speech-recognition transcripts, tolerating small recognition errors
/// ("Digonta" for "Diganta") and possessives ("Diganta's").
public enum NameMatcher {
    public static func parseNames(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !normalize($0).isEmpty }
    }

    /// Every occurrence of any name in `transcript`, in order (the display form of the name).
    public static func matches(in transcript: String, names: [String]) -> [String] {
        let words = tokens(transcript)
        guard !words.isEmpty else { return [] }
        var found: [String] = []
        var i = 0
        while i < words.count {
            var matchedLength = 0
            for name in names {
                let nameWords = tokens(name)
                guard !nameWords.isEmpty, i + nameWords.count <= words.count else { continue }
                let window = Array(words[i..<(i + nameWords.count)])
                if zip(window, nameWords).allSatisfy({ wordMatches($0, $1) }) {
                    found.append(name)
                    matchedLength = max(matchedLength, nameWords.count)
                    break
                }
            }
            i += max(1, matchedLength)
        }
        return found
    }

    static func wordMatches(_ heard: String, _ name: String) -> Bool {
        if heard == name { return true }
        // Possessive or plural: "digantas", "diganta's" (apostrophes are stripped by normalize).
        if heard.hasPrefix(name), heard.count <= name.count + 2, name.count >= 3 { return true }
        // Small recognition errors on longer names only (short names must match exactly).
        let allowed = name.count >= 8 ? 2 : (name.count >= 5 ? 1 : 0)
        return allowed > 0 && abs(heard.count - name.count) <= allowed && levenshtein(heard, name) <= allowed
    }

    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var out = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == "'" || ch == "’" { continue }
            else { out.append(" ") }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }
}

// MARK: - Voice activity (for auto-duck)

public struct SpeechActivityParams: Equatable, Sendable {
    /// Minimum voice-band RMS for "someone is talking close by".
    public var minLevel: Double
    /// Voice-band energy must exceed the background by this factor.
    public var backgroundRatio: Double = 4
    /// How long speech must be (mostly) present before ducking, and how long it must be quiet before restoring.
    public var onsetTime: Double = 0.35
    public var releaseTime: Double = 1.2

    public init(minLevel: Double = 0.01) {
        self.minLevel = minLevel
    }

    /// 0 = only loud, close voices (RMS 0.03) … 1 = quieter voices (0.004).
    public static func forSensitivity(_ sensitivity: Double) -> SpeechActivityParams {
        let s = min(max(sensitivity, 0), 1)
        return SpeechActivityParams(minLevel: 0.03 * pow(0.004 / 0.03, s))
    }
}

/// Detects someone talking close to the Mac: sustained energy in the voice band (300–3400 Hz) well
/// above the background and above an absolute level. Knocks and clicks are too short; fans and room
/// noise are part of the background. Not thread-safe: call from one queue.
public final class SpeechActivityDetector {
    public enum Event: Equatable, Sendable { case started, ended }

    public var params: SpeechActivityParams
    public let sampleRate: Double
    public private(set) var isSpeaking = false

    private var highPass: Biquad
    private var lowPass: Biquad
    private let frameLength: Int
    private var frameFill = 0
    private var frameEnergy = 0.0
    private var background: [Double] = []         // recent non-speech frame energies
    private var recent: [Bool] = []               // voiced flags, newest last
    private var energies: [Double] = []           // last ~0.6 s of frame energies (for the rhythm check)

    public init(sampleRate: Double, params: SpeechActivityParams) {
        self.sampleRate = sampleRate
        self.params = params
        highPass = .highPass(cutoff: 300, sampleRate: sampleRate)
        lowPass = .lowPass(cutoff: min(3400, sampleRate * 0.45), sampleRate: sampleRate)
        frameLength = max(64, Int(sampleRate * 0.02))
    }

    private var frameSeconds: Double { Double(frameLength) / sampleRate }

    public func process(_ samples: [Float]) -> [Event] {
        var events: [Event] = []
        for sample in samples {
            let y = lowPass.process(highPass.process(Double(sample)))
            frameEnergy += y * y
            frameFill += 1
            if frameFill == frameLength, let event = endFrame() { events.append(event) }
        }
        return events
    }

    private func endFrame() -> Event? {
        let energy = frameEnergy / Double(frameLength)
        frameEnergy = 0
        frameFill = 0

        energies.append(energy)
        let rhythmWindow = Int(0.6 / frameSeconds)
        if energies.count > rhythmWindow { energies.removeFirst(energies.count - rhythmWindow) }
        // Speech rises and falls with syllables; fans, hum and steady noise don't.
        let mean = energies.reduce(0, +) / Double(energies.count)
        let variance = energies.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(energies.count)
        let modulation = mean > 0 ? variance.squareRoot() / mean : 0
        let steady = energies.count >= rhythmWindow / 2 && modulation < 0.3

        let floor = backgroundLevel()
        let voiced = !steady && energy > max(floor * params.backgroundRatio, params.minLevel * params.minLevel)
        // Learn the background from stretches with no voice (the quiet gaps between syllables belong
        // to the speech, not to the room) and from any steady sound.
        let quietStretch = Int(0.5 / frameSeconds)
        if steady || (!voiced && !isSpeaking && !recent.suffix(quietStretch).contains(true)) {
            background.append(energy)
            let keep = Int(3 / frameSeconds)
            if background.count > keep { background.removeFirst(background.count - keep) }
        }
        recent.append(voiced)
        let window = Int(max(params.onsetTime, params.releaseTime) / frameSeconds) + 1
        if recent.count > window { recent.removeFirst(recent.count - window) }

        func voicedFraction(over seconds: Double) -> Double {
            let n = min(recent.count, max(1, Int(seconds / frameSeconds)))
            return Double(recent.suffix(n).filter { $0 }.count) / Double(n)
        }

        if !isSpeaking, recent.count >= Int(params.onsetTime / frameSeconds), voicedFraction(over: params.onsetTime) >= 0.5 {
            isSpeaking = true
            return .started
        }
        if isSpeaking, recent.count >= Int(params.releaseTime / frameSeconds), voicedFraction(over: params.releaseTime) < 0.15 {
            isSpeaking = false
            return .ended
        }
        return nil
    }

    private func backgroundLevel() -> Double {
        guard !background.isEmpty else { return 1e-9 }
        let sorted = background.sorted()
        return max(1e-9, sorted[sorted.count / 5])        // 20th percentile: robust to bursts
    }
}
