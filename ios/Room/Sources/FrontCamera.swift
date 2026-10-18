import SwiftUI
import AVFoundation
import CoreImage
import Vision

#if targetEnvironment(simulator)
private final class CameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    var receiveFrame: ((UIImage?) -> Void)?
    var onFailure: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    #if DEBUG
    var diagnostic: [String: Any] = [:]
    #endif
    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8790" + path)!)
        request.httpMethod = method
        request.timeoutInterval = path == "/camera/start" ? 120 : 5
        request.setValue("Bearer " + DeviceConnection.simulatorCameraToken, forHTTPHeaderField: "Authorization")
        return request
    }
    func start() async throws {
        let token = UUID(); generation = token
        let (data, response) = try await URLSession.shared.data(for: request("/camera/start", method: "POST"))
        guard generation == token else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "MacCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "请先打开 Mac 上的伴伴录制助手。"])
        }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                do {
                    let (bytes, response) = try await URLSession.shared.data(for: self.request("/camera/frame"))
                    guard !Task.isCancelled, self.generation == token else { return }
                    if (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: bytes) {
                        self.receiveFrame?(image); failures = 0
                        #if DEBUG
                        self.diagnostic = ["source": "Mac camera", "width": image.size.width, "height": image.size.height]
                        #endif
                    } else if (response as? HTTPURLResponse)?.statusCode != 204 { failures += 1 }
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                }
                if failures >= 3 {
                    self.onFailure?("Mac 摄像头连接已断开，请打开伴伴录制助手后重新开启摄像头。")
                    self.stop(); return
                }
                try? await Task.sleep(for: .milliseconds(65))
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        let stop = request("/camera/stop", method: "POST")
        Task { _ = try? await URLSession.shared.data(for: stop) }
        DispatchQueue.main.async { self.receiveFrame?(nil) }
    }
}
#else
private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "room.front-camera", qos: .userInitiated)
    private let frames = DispatchQueue(label: "room.camera-frames", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let output = AVCaptureVideoDataOutput()
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var configured = false
    private var frameCount = 0
    private var faces: [CGRect] = []
    private var lastExtent = CGRect.zero
    private let deliveryLock = NSLock()
    private var deliveryPending = false
    var receiveFrame: ((UIImage?) -> Void)?
    var onFailure: ((String) -> Void)?
    #if DEBUG
    var diagnostic: [String: Any] = [:]
    #endif

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.configured { try self.configure() }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw self.failure("摄像头未能启动，请重试。") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "FrontCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Capture video only; speech owns the application's audio session.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.usesApplicationAudioSession = false
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { throw failure("暂时无法使用前置摄像头。") }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw failure("摄像头正在被占用，请稍后再试。") }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: frames)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        // Sensor mounting differs across iPhone models: never hard-code a 90° turn.
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        coordinator = rotation
        setRotation(rotation.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.queue.async { self?.setRotation(angle) }
        }
        configured = true
    }
    private func setRotation(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.frames.async { self.faces = []; self.frameCount = 0 }
            DispatchQueue.main.async { self.receiveFrame?(nil) }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Limit presentation work while preserving the speech engine's headroom.
        frameCount += 1
        guard frameCount % 2 == 0, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliveryLock.lock()
        if deliveryPending { deliveryLock.unlock(); return }
        deliveryPending = true; deliveryLock.unlock()
        let original = CIImage(cvPixelBuffer: buffer)
        if frameCount % 12 == 2 || original.extent != lastExtent {
            let request = VNDetectFaceRectanglesRequest()
            if (try? VNImageRequestHandler(ciImage: original, orientation: .up).perform([request])) != nil {
                faces = (request.results ?? []).map(\.boundingBox)
            } else { faces = [] }
            lastExtent = original.extent
        }
        let result = naturalBeauty(original)
        let image = context.createCGImage(result, from: original.extent).map { UIImage(cgImage: $0) }
        #if DEBUG
        let diagnostic: [String: Any] = ["width": Int(original.extent.width), "height": Int(original.extent.height), "rotation": connection.videoRotationAngle, "mirrored": connection.isVideoMirrored, "faces": faces.count, "frames": frameCount, "beauty": "light-face-only"]
        #endif
        DispatchQueue.main.async {
            #if DEBUG
            self.diagnostic = diagnostic
            #endif
            self.receiveFrame?(image)
            self.deliveryLock.lock(); self.deliveryPending = false; self.deliveryLock.unlock()
        }
    }
    private func naturalBeauty(_ image: CIImage) -> CIImage {
        guard !faces.isEmpty else { return image }
        let extent = image.extent
        var mask = CIImage(color: .black).cropped(to: extent)
        // Soft cheek / forehead masks leave eyes, brows, lips and the background crisp.
        for face in faces {
            let rect = CGRect(x: face.minX * extent.width, y: face.minY * extent.height, width: face.width * extent.width, height: face.height * extent.height)
            for (x, y, scale) in [(0.27, 0.40, 0.22), (0.73, 0.40, 0.22), (0.50, 0.81, 0.21)] {
                let radius = rect.width * scale
                let spot = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y), "inputRadius0": radius * 0.25, "inputRadius1": radius, "inputColor0": CIColor(red: 0.42, green: 0.42, blue: 0.42), "inputColor1": CIColor.black])!.outputImage!.cropped(to: extent)
                mask = spot.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            }
        }
        let softened = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.025, "inputSharpness": 0.45])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.07])
        return softened.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]).cropped(to: extent)
    }
}

#endif

@MainActor
final class FrontCamera: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published var expanded = false
    var onError: ((String) -> Void)?
    private let capture = CameraCapture()
    #if DEBUG
    var diagnostic: [String: Any] { capture.diagnostic }
    #endif
    private var operation = UUID()
    private var interruption: NSObjectProtocol?
    func displayFrames(_ handler: @escaping (UIImage?) -> Void) { capture.receiveFrame = handler }
    init() {
        capture.onFailure = { [weak self] message in
            Task { @MainActor in self?.stop(); self?.onError?(message) }
        }
        interruption = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: capture.session, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                self.stop(); self.onError?("摄像头暂时被占用，可以稍后重新开启。")
            }
        }
    }
    func toggle() {
        if enabled || starting { stop(); return }
        let token = UUID(); operation = token; starting = true
        Task {
            let allowed: Bool
            #if targetEnvironment(simulator)
            allowed = true // The Mac helper owns and requests physical camera permission.
            #else
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            #endif
            guard operation == token else { return }
            guard allowed else { starting = false; onError?("请在系统设置中允许相机权限，以开启自己的画面。"); return }
            do {
                try await capture.start()
                guard operation == token else { return }
                enabled = true; starting = false
            } catch {
                guard operation == token else { return }
                starting = false; onError?(error.localizedDescription)
            }
        }
    }
    func swap() { guard enabled else { return }; expanded.toggle() }
    func stop() { operation = UUID(); enabled = false; starting = false; expanded = false; capture.stop() }
    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }
}
struct CameraSurface: UIViewRepresentable {
    let camera: FrontCamera
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill; view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        camera.displayFrames { [weak view] image in view?.image = image }
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {}
}
