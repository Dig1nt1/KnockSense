import AppKit
import AVFoundation
import CoreImage
import Foundation

/// Webcam for Laptop Guard.
///
/// While the guard is armed the camera can be kept running ("warm"), holding the last ~2 s of
/// frames in memory. A trigger then saves the frame from *just before* it happened — the moment
/// someone reached for the Mac — with no start-up delay. If the camera isn't warm, it is started
/// on demand and the first well-exposed frame is used.
final class GuardCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "app.knocksense.camera", qos: .userInitiated)
    private let ciContext = CIContext()

    // Everything below is only touched on `queue`.
    private var configured = false
    private var sessionStart = 0.0
    private var frames: [(time: Double, image: CGImage)] = []
    private var lastKept = 0.0
    private var waiters: [Int: CheckedContinuation<CGImage?, Never>] = [:]
    private var nextWaiterID = 0

    /// Frames kept per second while warm, and how many seconds of history to hold.
    private let keepInterval = 0.25
    private let historySeconds = 2.0
    /// Ignore the first moments after a cold start (auto-exposure is still adjusting).
    private let warmUpSeconds = 0.6

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Starts the camera and keeps it running (green light on) until `stop()`.
    func start() {
        guard Self.authorized else { return }
        queue.async { self.startSession() }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.frames.removeAll()
            let pending = self.waiters
            self.waiters.removeAll()
            pending.values.forEach { $0.resume(returning: nil) }
        }
    }

    /// A JPEG photo. With a warm camera this is instant: the frame from about `secondsAgo` before
    /// now. Otherwise the camera is started and the first properly exposed frame is used.
    func photo(secondsAgo: Double = 0) async -> Data? {
        guard Self.authorized else { return nil }
        let image: CGImage? = await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            queue.async {
                let now = CFAbsoluteTimeGetCurrent()
                let target = now - secondsAgo
                if let best = self.frames.min(by: { abs($0.time - target) < abs($1.time - target) }),
                   now - best.time < max(1, secondsAgo + 0.6) {
                    continuation.resume(returning: best.image)
                    return
                }
                // Not warm: start (if needed) and wait for the next good frame.
                self.startSession()
                let id = self.nextWaiterID
                self.nextWaiterID += 1
                self.waiters[id] = continuation
                self.queue.asyncAfter(deadline: .now() + 6) {
                    self.waiters.removeValue(forKey: id)?.resume(returning: nil)
                }
            }
        }
        return image.flatMap(Self.jpeg)
    }

    // MARK: - Capture

    private func startSession() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
            if session.canAddInput(input) { session.addInput(input) }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            configured = true
        }
        if !session.isRunning {
            frames.removeAll()
            sessionStart = CFAbsoluteTimeGetCurrent()
            session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        let warmedUp = now - sessionStart >= warmUpSeconds
        // Convert only a few frames per second (or immediately when someone is waiting).
        guard warmedUp, now - lastKept >= keepInterval || !waiters.isEmpty,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        // createCGImage copies the pixels, so the camera's buffer is released right away.
        guard let frame = ciContext.createCGImage(image, from: image.extent) else { return }
        lastKept = now
        frames.append((now, frame))
        frames.removeAll { now - $0.time > historySeconds }
        let pending = waiters
        waiters.removeAll()
        pending.values.forEach { $0.resume(returning: frame) }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: - Saving

    /// Saves a photo into ~/Pictures/KnockSense Guard and returns its location.
    static func save(_ data: Data, label: String = "") -> URL? {
        let folder = photosFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let suffix = label.isEmpty ? "" : " \(label)"
        let url = folder.appendingPathComponent("Guard \(formatter.string(from: Date()))\(suffix).jpg")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static var photosFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnockSense Guard", isDirectory: true)
    }
}
