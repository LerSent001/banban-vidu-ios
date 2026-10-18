import AVFoundation
import Speech

// The audio callback owns only this locked sink, never main-actor UI state.
private final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func replace(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        request = value
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }
}

@MainActor
final class VoiceInput {
    var onLevel: ((Double) -> Void)?
    var onBands: (([Double]) -> Void)?
    var onListening: ((Bool) -> Void)?
    var onUtterance: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onDiagnostic: (([String: Any]) -> Void)?
    var configureSession: (() throws -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var engine = AVAudioEngine()
    private let sink = SpeechAudioSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var tapInstalled = false
    private var enabled = false
    private var generation = UUID()
    private var text = ""
    private var lastChange = Date.distantPast
    private var lastVoice = Date.distantPast
    private var began = Date()
    private var failures = 0
    private var noiseFloor = 0.001
    private var prepared = false
    private var observers: [NSObjectProtocol] = []
    private var recovery: Task<Void, Never>?
    private var recoveryCount = 0
    private var lastCapture = Date.distantPast
    private var healthySince = Date()
    private var captureGeneration = UUID()
    private var smoothedLevel = 0.0
    private var smoothedBands = Array(repeating: 0.0, count: 12)
    var captureIsHealthy: Bool { prepared && engine.isRunning && Date().timeIntervalSince(lastCapture) < 1 }


    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    func prepare() throws {
        stop()
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "VoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "中文语音识别暂时不可用，请检查网络及系统语音设置。"])
        }
        prepared = true
        do { try startCapture() } catch { stop(); throw error }
        for name in [Notification.Name.AVAudioEngineConfigurationChange, AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                let kind = notification.name.rawValue
                Task { @MainActor in
                    guard let self, self.prepared else { return }
                    self.onDiagnostic?(["audioEvent": kind, "running": self.engine.isRunning])
                    if !self.engine.isRunning { self.recoverCapture() }
                }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func startCapture() throws {
        try configureSession?()
        let input = engine.inputNode
        #if !targetEnvironment(simulator)
        try input.setVoiceProcessingEnabled(true)
        #endif
        // Simulator uses the Mac's selected input directly; avoid an extra VoIP device.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceInput", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风，请检查音频设备。"])
        }
        let sink = sink
        let spectrum = VoiceSpectrum(sampleRate: format.sampleRate)
        let captureToken = UUID(); captureGeneration = captureToken
        var lastMeter = 0.0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            sink.append(buffer)
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMeter >= 0.05, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            lastMeter = now
            var energy: Float = 0
            for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
            let rms = Double(sqrt(energy / Float(buffer.frameLength)))
            let bands = spectrum.levels(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            Task { @MainActor in
                guard let self, self.captureGeneration == captureToken, self.prepared else { return }
                self.lastCapture = Date(); self.meter(rms, bands: bands)
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        lastCapture = Date(); healthySince = Date()
        onDiagnostic?(["capture": "started", "sampleRate": format.sampleRate, "channels": format.channelCount])
    }

    private func recoverCapture() {
        guard prepared, recovery == nil else { return }
        cancelTurn(); onLevel?(0)
        recovery = Task { @MainActor [weak self] in
            // Defer rebuilding until the system / WebKit route transition settles.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.prepared else { return }
            self.recoveryCount += 1
            if self.recoveryCount > 4 {
                self.recovery = nil
                self.fail("麦克风暂时无法恢复，请检查是否有其他通话占用麦克风后再试。")
                return
            }
            self.engine.stop()
            if self.tapInstalled { self.engine.inputNode.removeTap(onBus: 0); self.tapInstalled = false }
            self.engine = AVAudioEngine()
            do {
                try self.startCapture()
                self.onDiagnostic?(["capture": "recovered", "attempt": self.recoveryCount])
                self.recovery = nil
                if self.enabled { self.beginTurn() }
            } catch {
                self.onDiagnostic?(["capture": "recoveryFailed", "code": (error as NSError).code])
                self.recovery = nil
                self.recoverCapture()
            }
        }
    }

    func setListening(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { failures = 0; beginTurn() }
        else { cancelTurn(); onLevel?(0) }
    }

    #if targetEnvironment(simulator)
    func preflightRecognition() async throws {
        guard let recognizer, prepared, engine.isRunning else {
            throw NSError(domain: "VoiceInput", code: 3, userInfo: [NSLocalizedDescriptionKey: "麦克风尚未准备好。"])
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = false
        var initializationError: NSError?
        let task = recognizer.recognitionTask(with: request) { _, error in
            Task { @MainActor in
                if let error = error as NSError?, error.code != 1110 { initializationError = error }
            }
        }
        sink.replace(request)
        defer { sink.replace(nil); request.endAudio(); task.cancel() }
        try await Task.sleep(for: .milliseconds(1500))
        if let initializationError { throw initializationError }
    }
    #endif

    private func beginTurn() {
        cancelTurn()
        guard enabled else { return }
        guard engine.isRunning, recovery == nil else { recoverCapture(); return }
        guard let recognizer, recognizer.isAvailable else {
            if enabled { fail("语音输入已中断，请结束通话后重新连接。") }
            return
        }
        let token = UUID(); generation = token
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        #if targetEnvironment(simulator)
        // Simulator can report support even when its local recognition model
        // cannot initialize. Allow Apple's network recognizer on this target.
        request.requiresOnDeviceRecognition = false
        #else
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        #endif
        self.request = request
        began = Date(); lastVoice = .distantPast; lastChange = .distantPast
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error as NSError?
            Task { @MainActor in
                guard let self, self.enabled, self.generation == token else { return }
                if let words, words != self.text {
                    self.text = words; self.lastChange = Date(); self.failures = 0
                }
                if final {
                    if self.text.isEmpty { self.beginTurn() } else { self.submit() }
                } else if let failure {
                    self.onDiagnostic?(["recognitionError": failure.domain, "code": failure.code, "message": failure.localizedDescription])
                    // A normal no-speech timeout opens a fresh recognition task.
                    if failure.code == 1110 { self.beginTurn() }
                    else if self.failures < 2 {
                        self.failures += 1
                        self.cancelTurn()
                        let retryToken = self.generation
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(450))
                            guard let self, self.enabled, self.generation == retryToken else { return }
                            self.beginTurn()
                        }
                    } else { self.fail("语音识别暂时失败，请重新连接。" + failure.localizedDescription) }
                }
            }
        }
        sink.replace(request)
        onListening?(true)
    }

    private func meter(_ rms: Double, bands: [Double]) {
        guard enabled, request != nil, engine.isRunning else { resetWaveform(); return }
        if rms < noiseFloor * 2 { noiseFloor = noiseFloor * 0.97 + rms * 0.03 }
        if rms > max(0.009, noiseFloor * 3) { lastVoice = Date() }
        let gate = max(0.004, noiseFloor * 2.5)
        let level = rms > gate ? max(0, min(1, (20 * log10(rms) + 48) / 35)) : 0
        smoothedLevel = level > smoothedLevel ? level : smoothedLevel * 0.48
        if smoothedLevel < 0.025 { smoothedLevel = 0 }
        onLevel?(smoothedLevel)
        for index in smoothedBands.indices {
            let target = level > 0 ? min(1, bands[index] * 0.82 + level * 0.18) : 0
            let response = target > smoothedBands[index] ? 0.7 : 0.3
            smoothedBands[index] += (target - smoothedBands[index]) * response
            if smoothedBands[index] < 0.015 { smoothedBands[index] = 0 }
        }
        onBands?(smoothedBands)
    }

    private func tick() {
        guard prepared, recovery == nil else { return }
        guard engine.isRunning, Date().timeIntervalSince(lastCapture) < 3 else { recoverCapture(); return }
        if Date().timeIntervalSince(healthySince) > 5 { recoveryCount = 0 }
        guard enabled else { return }
        let now = Date()
        // Both recognition changes and actual sound must settle before sending.
        if !text.isEmpty, now.timeIntervalSince(lastChange) > 1.1, now.timeIntervalSince(lastVoice) > 0.75 {
            submit()
        } else if now.timeIntervalSince(began) > 45 {
            if text.isEmpty { beginTurn() } else { submit() }
        }
    }

    private func submit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        enabled = false
        cancelTurn() // Invalidate late partial/final callbacks before delivering once.
        onLevel?(0)
        onUtterance?(words)
    }

    private func cancelTurn() {
        generation = UUID()
        sink.replace(nil)
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        text = ""
        onListening?(false)
        resetWaveform()
    }

    private func resetWaveform() {
        smoothedLevel = 0; smoothedBands = Array(repeating: 0, count: 12)
        onLevel?(0); onBands?(smoothedBands)
    }

    #if DEBUG
    func simulateRouteReset() { engine.stop() }
    #endif

    private func fail(_ message: String) { stop(); onError?(message) }

    func stop() {
        prepared = false; captureGeneration = UUID()
        recovery?.cancel(); recovery = nil; recoveryCount = 0
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        enabled = false
        timer?.invalidate(); timer = nil
        cancelTurn()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        noiseFloor = 0.001; smoothedLevel = 0
        onLevel?(0)
    }
}
