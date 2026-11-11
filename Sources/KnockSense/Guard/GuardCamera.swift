import AVFoundation
import Foundation

/// Takes still photos with the built-in camera.
final class GuardCamera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "app.knocksense.camera")
    private var pending: CheckedContinuation<Data?, Never>?   // only touched on `queue`
    private var captureToken = 0                                // only touched on `queue`

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// One JPEG photo, or nil if the camera isn't available or allowed.
    func snap() async -> Data? {
        guard Self.authorized else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            queue.async {
                guard self.pending == nil, let device = AVCaptureDevice.default(for: .video) else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    if self.session.inputs.isEmpty {
                        let input = try AVCaptureDeviceInput(device: device)
                        self.session.beginConfiguration()
                        self.session.sessionPreset = .photo
                        if self.session.canAddInput(input) { self.session.addInput(input) }
                        if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                        self.session.commitConfiguration()
                    }
                    if !self.session.isRunning {
                        self.session.startRunning()
                        Thread.sleep(forTimeInterval: 1.2)     // let exposure and focus settle
                    }
                    self.pending = continuation
                    self.captureToken += 1
                    let token = self.captureToken
                    let settings = self.output.availablePhotoCodecTypes.contains(.jpeg)
                        ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                        : AVCapturePhotoSettings()
                    self.output.capturePhoto(with: settings, delegate: self)
                    // Never hang if the camera doesn't answer.
                    self.queue.asyncAfter(deadline: .now() + 5) {
                        if self.captureToken == token { self.finish(with: nil) }
                    }
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async { self.finish(with: data) }
    }

    private func finish(with data: Data?) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: data)
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Saves a photo into ~/Pictures/KnockSense Guard and returns its location.
    static func save(_ data: Data) -> URL? {
        let folder = photosFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("Guard \(formatter.string(from: Date())).jpg")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static var photosFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnockSense Guard", isDirectory: true)
    }
}
