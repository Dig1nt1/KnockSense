import Darwin
import Foundation
import KnockCore

/// Talks to the `knocksense-imu` root helper over its Unix socket and turns the accelerometer
/// stream into knocks. Reconnects automatically.
final class MotionSensor: @unchecked Sendable {
    /// Must match `helperVersion` in Sources/KnockSenseIMU/main.swift. Bump both when the helper changes.
    static let expectedHelperVersion = 1
    static let socketPath = "/var/run/knocksense-imu.sock"

    enum State: Equatable, Sendable {
        case stopped
        /// Socket missing: helper not installed (or not running).
        case helperNotRunning
        case connecting
        case streaming
        case noSensor
        case helperOutdated(installed: Int)
        case error(String)
    }

    var onTap: (@Sendable (TapEvent) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onState: (@Sendable (State) -> Void)?

    private let queue = DispatchQueue(label: "app.knocksense.motion", qos: .userInitiated)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var helloReceived = false
    private var running = false
    private var detector: TapDetector
    private var lastLevelTime = 0.0
    private var lastSampleTime = 0.0
    private var state: State = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }

    init(params: TapParams) {
        detector = TapDetector(params: params)
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.disconnect()
            self.state = .stopped
        }
    }

    func updateParams(_ params: TapParams) {
        queue.async { self.detector.params = params }
    }

    // MARK: - Connection (all on `queue`)

    private func connect() {
        guard running, fd < 0 else { return }
        guard FileManager.default.fileExists(atPath: Self.socketPath) else {
            state = .helperNotRunning
            retryLater()
            return
        }
        state = .connecting
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            state = .error("Couldn't create a socket.")
            retryLater()
            return
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in pathBytes.prefix(raw.count - 1).enumerated() { raw[i] = byte }
            raw[min(pathBytes.count, raw.count - 1)] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(socketFD)
            state = .helperNotRunning
            retryLater()
            return
        }
        _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
        fd = socketFD
        buffer.removeAll()
        helloReceived = false
        detector = TapDetector(params: detector.params)

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(socketFD) }
        source.resume()
        readSource = source
    }

    private func disconnect() {
        readSource?.cancel()        // closes the fd in the cancel handler
        readSource = nil
        fd = -1
    }

    private func retryLater() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
            processLines()
        } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
            // Helper quit or restarted.
            disconnect()
            if running {
                state = .helperNotRunning
                retryLater()
            }
        }
    }

    private func processLines() {
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if helloReceived {
                handleSample(line)
            } else {
                handleHello(line)
            }
        }
    }

    private func handleHello(_ line: String) {
        helloReceived = true
        let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
        guard parts.count >= 3, parts[0] == "KSIMU", let version = Int(parts[1]) else {
            state = .error("Unexpected reply from the motion helper.")
            return
        }
        if version != Self.expectedHelperVersion {
            state = .helperOutdated(installed: version)
            return
        }
        switch parts[2] {
        case "ok": state = .streaming
        case "nosensor": state = .noSensor
        default: state = .error("The motion sensor couldn't be opened (\(parts.dropFirst(3).joined(separator: " "))).")
        }
    }

    private func handleSample(_ line: String) {
        guard state == .streaming else { return }
        let parts = line.split(separator: " ")
        guard parts.count == 5, parts[0] == "s",
              let t = Double(parts[1]), let x = Double(parts[2]), let y = Double(parts[3]), let z = Double(parts[4]) else { return }
        lastSampleTime = t
        if let tap = detector.process(t: t, x: x, y: y, z: z) {
            onTap?(tap)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelTime > 0.066 {
            lastLevelTime = now
            onLevel?(Float(detector.takeLevel()))
        }
    }
}

/// Installs / removes the root helper as a LaunchDaemon, using the standard macOS admin password prompt.
enum MotionHelperInstaller {
    static let label = "com.knocksense.imu"
    static let installedBinary = "/Library/PrivilegedHelperTools/com.knocksense.imu"
    static let installedPlist = "/Library/LaunchDaemons/com.knocksense.imu.plist"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedBinary) && FileManager.default.fileExists(atPath: installedPlist)
    }

    /// Returns nil on success, or an error message. Blocks while the password prompt is shown.
    @MainActor
    static func install() -> String? {
        let bundle = Bundle.main.bundleURL
        let helper = bundle.appendingPathComponent("Contents/Helpers/knocksense-imu").path
        let plist = bundle.appendingPathComponent("Contents/Resources/\(label).plist").path
        guard FileManager.default.isExecutableFile(atPath: helper), FileManager.default.fileExists(atPath: plist) else {
            return "This copy of KnockSense doesn't include the motion helper. Please update KnockSense."
        }
        let script = """
        set -e
        /bin/mkdir -p /Library/PrivilegedHelperTools
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/cp "$1" \(installedBinary)
        /usr/sbin/chown root:wheel \(installedBinary)
        /bin/chmod 755 \(installedBinary)
        /usr/bin/xattr -c \(installedBinary) 2>/dev/null || true
        /bin/cp "$2" \(installedPlist)
        /usr/sbin/chown root:wheel \(installedPlist)
        /bin/chmod 644 \(installedPlist)
        /bin/launchctl bootstrap system \(installedPlist)
        """
        return runAsAdmin(script: script, arguments: [helper, plist],
                          prompt: "KnockSense wants to install its motion-sensor helper.")
    }

    @MainActor
    static func uninstall() -> String? {
        let script = """
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/rm -f \(installedPlist) \(installedBinary) \(MotionSensor.socketPath)
        """
        return runAsAdmin(script: script, arguments: [], prompt: "KnockSense wants to remove its motion-sensor helper.")
    }

    /// Runs a fixed shell script as root via AppleScript's administrator prompt. Paths are passed as
    /// separate, quoted arguments, never spliced into the script text.
    @MainActor
    private static func runAsAdmin(script: String, arguments: [String], prompt: String) -> String? {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var command = "\"/bin/sh -c \" & quoted form of \(literal(script)) & \" knocksense\""
        for argument in arguments {
            command += " & \" \" & quoted form of \(literal(argument))"
        }
        let source = "do shell script \(command) with prompt \(literal(prompt)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled." }
        return (error[NSAppleScript.errorMessage] as? String) ?? "The helper couldn't be installed."
    }
}
