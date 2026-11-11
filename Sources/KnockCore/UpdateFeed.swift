import Foundation

/// Contents of `version.json`, published next to KnockSense.zip on the GitHub "latest" release.
public struct UpdateInfo: Codable, Equatable, Sendable {
    /// Monotonically increasing build number (the GitHub Actions run number).
    public let build: Int
    public let version: String
    public let commit: String
    /// SHA-256 of the zip, lowercase hex.
    public let sha256: String
    /// Where to download the zip.
    public let url: String

    public init(build: Int, version: String, commit: String, sha256: String, url: String) {
        self.build = build
        self.version = version
        self.commit = commit
        self.sha256 = sha256
        self.url = url
    }
}

public enum UpdatePolicy {
    public static func isNewer(_ info: UpdateInfo, thanBuild currentBuild: Int) -> Bool {
        info.build > currentBuild
    }

    /// Why the running app can't replace itself, or nil if it can.
    public static func installProblem(appPath: String, parentIsWritable: Bool) -> String? {
        if !appPath.hasSuffix(".app") && !appPath.hasSuffix(".app/") {
            return "KnockSense isn't running from an app bundle, so it can't update itself."
        }
        // macOS runs apps opened straight from Downloads (or a zip) from a read-only shadow copy.
        if appPath.contains("/AppTranslocation/") {
            return "Move KnockSense.app into your Applications folder, open it from there, then try again."
        }
        if !parentIsWritable {
            return "KnockSense doesn't have permission to replace itself in this folder."
        }
        return nil
    }

    /// Accepts only well-formed checksums and HTTPS download links.
    public static func isValid(_ info: UpdateInfo) -> Bool {
        let hex = info.sha256.lowercased()
        return hex.count == 64
            && hex.allSatisfy { $0.isHexDigit }
            && URL(string: info.url)?.scheme == "https"
            && info.build > 0
    }
}
