import AppKit
import CryptoKit
import Foundation
import KnockCore

/// Self-updater: reads `version.json` from the GitHub "latest" release, and if it's a newer build,
/// downloads the zip, verifies its SHA-256, swaps the app bundle in place and relaunches.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading
        case installing
        case failed(String)
    }

    enum UpdateError: LocalizedError {
        case server(Int)
        case invalidManifest
        case checksumMismatch
        case unzipFailed
        case invalidApp

        var errorDescription: String? {
            switch self {
            case .server(let code): return "The update server answered with an error (\(code))."
            case .invalidManifest: return "The update information is incomplete."
            case .checksumMismatch: return "The download was damaged (checksum mismatch). Please try again."
            case .unzipFailed: return "The downloaded update couldn't be unpacked."
            case .invalidApp: return "The downloaded file isn't a valid KnockSense app."
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?

    let currentVersion: String
    let currentBuild: Int
    private let feedURL: URL?
    private var automaticTask: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        feedURL = (bundle.object(forInfoDictionaryKey: "KSUpdateFeedURL") as? String).flatMap(URL.init(string:))
    }

    var versionText: String {
        currentBuild > 0 ? "\(currentVersion) (build \(currentBuild))" : "\(currentVersion) (built locally)"
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// Checks shortly after launch and then every 6 hours; only *announces* updates, never installs on its own.
    func startAutomaticChecks(whenEnabled enabled: @escaping @MainActor () -> Bool) {
        automaticTask?.cancel()
        automaticTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            while !Task.isCancelled {
                if enabled() { await self?.check(installIfAvailable: false, quiet: true) }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    /// The "Check for Updates" button: checks and, if there's a newer build, installs it right away.
    func checkAndInstall() async {
        await check(installIfAvailable: true, quiet: false)
    }

    func check(installIfAvailable: Bool, quiet: Bool) async {
        guard !isBusy else { return }
        guard let feedURL else {
            status = .failed("No update address is configured in this build.")
            return
        }
        let previous = status
        status = .checking
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.server(code) }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            guard UpdatePolicy.isValid(info) else { throw UpdateError.invalidManifest }
            lastChecked = Date()

            guard UpdatePolicy.isNewer(info, thanBuild: currentBuild) else {
                status = .upToDate
                return
            }
            status = .available(info)
            if installIfAvailable { await install(info) }
        } catch {
            // A background check that fails (offline, etc.) shouldn't leave an error on screen.
            status = quiet ? previous : .failed(error.localizedDescription)
        }
    }

    func install(_ info: UpdateInfo) async {
        guard !(status == .downloading || status == .installing) else { return }
        let running = Bundle.main.bundleURL
        let target: URL
        switch UpdatePolicy.installPlan(
            appPath: running.path,
            parentIsWritable: FileManager.default.isWritableFile(atPath: running.deletingLastPathComponent().path),
            applicationsIsWritable: FileManager.default.isWritableFile(atPath: "/Applications")
        ) {
        case .replace(let path), .installInto(let path):
            target = URL(fileURLWithPath: path)
        case .impossible(let problem):
            status = .failed(problem)
            return
        }
        guard let zipURL = URL(string: info.url) else {
            status = .failed(UpdateError.invalidManifest.localizedDescription)
            return
        }

        status = .downloading
        do {
            // Staging folder on the same volume as the app, so the final swap is a fast rename.
            let staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: target.deletingLastPathComponent(), create: true
            )
            let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError.server(code) }
            let zip = staging.appendingPathComponent("KnockSense.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            status = .installing
            let digest = try await Task.detached(priority: .userInitiated) { () throws -> String in
                let data = try Data(contentsOf: zip)
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }.value
            guard digest == info.sha256.lowercased() else { throw UpdateError.checksumMismatch }

            let unzipStatus = try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
            guard unzipStatus == 0 else { throw UpdateError.unzipFailed }

            let newApp = staging.appendingPathComponent("KnockSense.app")
            guard let newBundle = Bundle(url: newApp),
                  newBundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let executable = newBundle.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw UpdateError.invalidApp
            }
            try relaunch(replacing: target, with: newApp, staging: staging)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Hands off to a tiny shell script that waits for this process to quit, swaps the bundles
    /// (restoring the old one if anything goes wrong) and opens the new version.
    private func relaunch(replacing target: URL, with newApp: URL, staging: URL) throws {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        if [ -e "$2" ]; then
          /bin/rm -rf "$2.previous"
          if /bin/mv "$2" "$2.previous"; then
            if /bin/mv "$3" "$2"; then
              /bin/rm -rf "$2.previous"
            else
              /bin/mv "$2.previous" "$2"
            fi
          fi
        else
          /bin/mv "$3" "$2"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        /bin/rm -rf "$4"
        /usr/bin/open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "knocksense-updater",
                             String(ProcessInfo.processInfo.processIdentifier),
                             target.path, newApp.path, staging.path]
        try process.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
