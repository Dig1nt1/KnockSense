// knocksense-imu — tiny root helper that reads the MacBook's built-in accelerometer and streams it
// to KnockSense over a Unix socket.
//
// Apple doesn't expose this sensor through a public API. On Apple Silicon MacBooks (M2 and newer)
// it appears as an "AppleSPUHIDDevice" (vendor usage page 0xFF00, usage 3) whose reports carry
// x/y/z as little-endian Q16 fixed-point g at byte offsets 6, 10 and 14 of a 22-byte report.
// Opening it requires root, hence this helper (installed as a LaunchDaemon by KnockSense).
// Technique as documented by github.com/olvvier/apple-silicon-accelerometer.
//
// Protocol (text lines over /var/run/knocksense-imu.sock):
//   first line:  "KSIMU <version> ok" | "KSIMU <version> nosensor" | "KSIMU <version> error <details>"
//   then:        "s <seconds> <x> <y> <z>" per sample (g)
// The sensor is only switched on while at least one client is connected.

import Darwin
import Foundation
import IOKit
import IOKit.hid

let helperVersion = 1
let socketPath = "/var/run/knocksense-imu.sock"

if CommandLine.arguments.contains("--version") {
    print("knocksense-imu \(helperVersion)")
    exit(0)
}

signal(SIGPIPE, SIG_IGN)

// MARK: - Sensor

func registryInt(_ service: io_service_t, _ key: String) -> Int? {
    guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
    return value.takeRetainedValue() as? Int
}

/// Turns accelerometer reporting on/off on every SPU sensor driver.
func setSensorReporting(_ on: Bool) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        let value = NSNumber(value: on ? 1 : 0)
        IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, value)
        IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, value)
        if on {
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, NSNumber(value: 1000))
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

func findAccelerometer() -> IOHIDDevice? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        let isAccelerometer = registryInt(service, "PrimaryUsagePage") == 0xFF00 && registryInt(service, "PrimaryUsage") == 3
        if isAccelerometer, let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) {
            IOObjectRelease(service)
            return device
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return nil
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

func seconds(fromMachTime time: UInt64) -> Double {
    Double(time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

// MARK: - Socket server

final class Server {
    private var listenFD: Int32 = -1
    private var clients: [Int32] = []
    private var acceptSource: DispatchSourceRead?
    var hello = "KSIMU \(helperVersion) nosensor\n"
    var onClientCountChange: ((Int) -> Void)?

    var hasClients: Bool { !clients.isEmpty }

    func start() -> Bool {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in pathBytes.prefix(buffer.count - 1).enumerated() { buffer[i] = byte }
            buffer[min(pathBytes.count, buffer.count - 1)] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { return false }
        chmod(socketPath, 0o666)          // KnockSense runs as the logged-in user
        guard listen(listenFD, 8) == 0 else { return false }
        _ = fcntl(listenFD, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        acceptSource = source
        return true
    }

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            clients.append(fd)
            send(hello, to: fd)
            onClientCountChange?(clients.count)
        }
    }

    @discardableResult
    private func send(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // A full buffer just drops this sample; a closed connection removes the client.
        return written >= 0 || errno == EAGAIN || errno == EWOULDBLOCK
    }

    func broadcast(_ text: String) {
        let before = clients.count
        clients.removeAll { fd in
            if send(text, to: fd) { return false }
            close(fd)
            return true
        }
        if clients.count != before { onClientCountChange?(clients.count) }
    }
}

// MARK: - Main

let server = Server()
guard server.start() else {
    FileHandle.standardError.write("knocksense-imu: could not open \(socketPath) (run as root)\n".data(using: .utf8)!)
    exit(1)
}

let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)

if let device = findAccelerometer() {
    let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    if status == kIOReturnSuccess {
        server.hello = "KSIMU \(helperVersion) ok\n"
        let callback: IOHIDReportWithTimeStampCallback = { _, result, _, _, _, report, length, timestamp in
            guard result == kIOReturnSuccess, length == 22, server.hasClients else { return }
            let raw = UnsafeRawPointer(report)
            let x = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 6, as: Int32.self))) / 65536
            let y = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 10, as: Int32.self))) / 65536
            let z = Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 14, as: Int32.self))) / 65536
            let t = seconds(fromMachTime: timestamp)
            server.broadcast(String(format: "s %.6f %.5f %.5f %.5f\n", t, x, y, z))
        }
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, reportBuffer, 4096, callback, nil)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    } else {
        server.hello = "KSIMU \(helperVersion) error open 0x\(String(UInt32(bitPattern: status), radix: 16))\n"
    }
} else {
    server.hello = "KSIMU \(helperVersion) nosensor\n"
}

// Only power the sensor while KnockSense is connected.
server.onClientCountChange = { count in setSensorReporting(count > 0) }
setSensorReporting(false)

CFRunLoopRun()
