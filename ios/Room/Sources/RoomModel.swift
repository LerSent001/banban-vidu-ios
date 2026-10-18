import SwiftUI
import WebKit
import AVFoundation
import Speech

@MainActor
final class RoomModel: NSObject, ObservableObject {
    @Published var customCharacters: [Companion] = []
    @Published private var hiddenCharacterIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCharacterIDs") ?? [])
    var characters: [Companion] { Companion.all.filter { $0.id == Companion.all.first?.id || !hiddenCharacterIDs.contains($0.id) } + customCharacters }
    func canDelete(_ companion: Companion) -> Bool { !busy && characters.count > 1 && companion.id != Companion.all.first?.id }
    func deleteCharacter(_ companion: Companion) throws {
        guard canDelete(companion) else { return }
        let updated = customCharacters.filter { $0.id != companion.id }
        if companion.imagePath != nil {
            try JSONEncoder().encode(updated).write(to: Companion.directory.appendingPathComponent("characters.json"), options: .atomic)
            customCharacters = updated
        } else {
            hiddenCharacterIDs.insert(companion.id)
            UserDefaults.standard.set(Array(hiddenCharacterIDs), forKey: "hiddenCharacterIDs")
        }
        if selectedID == companion.id, let fallback = characters.first { select(fallback) }
        for prefix in ["name.", "voice.", "persona."] { UserDefaults.standard.removeObject(forKey: prefix + companion.id) }
        if let path = companion.imagePath { try? FileManager.default.removeItem(at: Companion.directory.appendingPathComponent(path)) }
    }
    @Published var selectedID = "xia"
    @Published var voice = "Serena"
    @Published var voiceReason = "已为小夏搭配温柔自然的苏瑶"
    @Published var matchingVoice = false
    @Published var speaker = true
    @Published var micLevel: Double = 0
    @Published var micBands = Array(repeating: 0.0, count: 12)
    let camera = FrontCamera()
    @Published var listening = false
    @Published var micTesting = false
    let voicePreview = VoicePreview()
    @Published var name = "小夏"
    @Published var persona = "你叫小夏，是一位温暖自然、喜欢音乐与日常聊天的虚拟角色。用普通话与用户交流，回答简短口语化，一次一到三句话，认真倾听，不要长篇说教。你身处温暖的卧室，坐在床边面向镜头。保持参考图中的外貌、衣着和房间布置。"
    @Published var image = UIImage(named: "bedroom") ?? UIImage()
    @Published var status = "正在准备房间"
    @Published var serviceReady = false
    @Published var pageReady = false
    @Published var checkingService = false
    @Published var connecting = false
    @Published var connected = false
    @Published var ending = false
    @Published var hasVideo = false
    @Published var muted = false
    @Published var error: String?
    @Published var liveID = ""
    @Published var startDate: Date?
    let webView: WKWebView
    private var bridge: RoomBridge!
    var busy: Bool { connecting || connected || ending }
    private var operation = UUID()
    private let voiceInput = VoiceInput()
    private var remoteSpeaking = false
    private var awaitingReply = false
    private var replyTimeout: Task<Void, Never>?
    #if DEBUG
    private var didCheckNetwork = false
    private func checkNetworkOnDevice() async {
        guard !didCheckNetwork, !busy else { return }
        didCheckNetwork = true
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date())]
        let endpoint = "https://rs.rtn.aliyuncs.com/roomserver/v1/ws/version"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 8
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            report["nativeHTTP"] = ["status": (response as? HTTPURLResponse)?.statusCode ?? 0, "seconds": Date().timeIntervalSince(started)]
        } catch {
            let failure = error as NSError
            report["nativeHTTP"] = ["domain": failure.domain, "code": failure.code, "message": failure.localizedDescription]
        }
        // Invalid credentials test only the handshake; this cannot create or join a paid room.
        let socketURL = "wss://rs.rtn.aliyuncs.com/roomserver/v1/ws?appid=network-probe-invalid&callid=network-probe&channelid=network-probe&userid=network-probe&nonce=probe&timestamp=1&token=invalid&authtype=app&tid=network-probe"
        let socket = URLSession.shared.webSocketTask(with: URL(string: socketURL)!)
        socket.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        do { _ = try await socket.receive(); report["nativeSocket"] = ["received": true] }
        catch {
            let failure = error as NSError
            report["nativeSocket"] = ["domain": failure.domain, "code": failure.code, "message": failure.localizedDescription, "httpStatus": (socket.response as? HTTPURLResponse)?.statusCode ?? 0]
        }
        timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil)
        let script = """
        const result = {};
        try { const response = await fetch(httpURL, {signal: AbortSignal.timeout(8000)}); result.http = {status: response.status}; }
        catch(error) { result.http = {error: error.name, message: error.message}; }
        result.socket = await new Promise(resolve => {
          const started = performance.now(), socket = new WebSocket(socketURL);
          const finish = event => { clearTimeout(timer); socket.close(); resolve({event, ms: Math.round(performance.now()-started)}); };
          const timer = setTimeout(() => finish('timeout'), 8000);
          socket.onopen = () => finish('open'); socket.onerror = () => finish('error');
        });
        return result;
        """
        do { report["web"] = try await webView.callAsyncJavaScript(script, arguments: ["httpURL": endpoint, "socketURL": socketURL], in: nil, contentWorld: .page) }
        catch { report["webError"] = error.localizedDescription }
        var hostingChecks: [[String: Any]] = []
        for origin in [DeviceConnection.baseURL] {
            var probe = origin == DeviceConnection.baseURL ? DeviceConnection.request("/health") : URLRequest(url: URL(string: origin + "/")!)
            probe.timeoutInterval = 10
            do {
                let (data, response) = try await DeviceConnection.session.data(for: probe)
                hostingChecks.append(["origin": origin, "status": (response as? HTTPURLResponse)?.statusCode ?? 0, "bytes": data.count])
            } catch { hostingChecks.append(["origin": origin, "error": error.localizedDescription, "code": (error as NSError).code]) }
        }
        report["hosting"] = hostingChecks
        await checkService()
        report["appService"] = ["baseURL": DeviceConnection.baseURL, "ready": serviceReady, "pageReady": pageReady]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("rtc-network-check.json")
            try? data.write(to: url, options: .atomic)
        }
    }
    private var didCheckMedia = false
    private func checkMediaOnDevice() async {
        guard !didCheckMedia, !busy else { return }
        didCheckMedia = true
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "catalogCount": CompanionVoice.all.count]
        var samples: [[String: Any]] = []
        for id in ["Katerina", "Momo", "Harvey", "Evan"] {
            guard let voice = CompanionVoice.all.first(where: { $0.id == id }) else { continue }
            voicePreview.toggle(voice)
            try? await Task.sleep(for: .seconds(2))
            samples.append(voicePreview.diagnostic)
            voicePreview.stop()
        }
        report["samples"] = samples
        camera.toggle()
        try? await Task.sleep(for: .seconds(5))
        report["camera"] = camera.diagnostic
        report["cameraEnabled"] = camera.enabled
        report["cameraError"] = error ?? ""
        camera.stop()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("voice-camera-check.json")
            try? data.write(to: url, options: .atomic)
        }
    }
    private var didCheckAudio = false
    #if targetEnvironment(simulator)
    private func checkSpeechOnSimulator() async {
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date())]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let probe = VoiceInput()
        probe.configureSession = { [weak self] in try self?.configureAudio() }
        var events: [[String: Any]] = []
        probe.onDiagnostic = { events.append($0) }
        probe.onError = { report["microphoneRecognitionError"] = $0 }
        report["speechAuthorized"] = await VoiceInput.authorize()
        report["microphoneAuthorized"] = await AVAudioApplication.requestRecordPermission()
        do {
            try probe.prepare()
            probe.setListening(true)
            try? await Task.sleep(for: .seconds(8))
            report["microphoneHealthy"] = probe.captureIsHealthy
        } catch { report["captureError"] = error.localizedDescription }
        probe.stop()
        report["events"] = events
        if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) {
            report["recognizerAvailable"] = recognizer.isAvailable
            report["supportsLocalRecognition"] = recognizer.supportsOnDeviceRecognition
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = false
            request.shouldReportPartialResults = true
            let task = recognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor in
                    if let result { report["fixtureText"] = result.bestTranscription.formattedString; report["fixtureFinal"] = result.isFinal }
                    if let error { report["fixtureError"] = String(describing: error) }
                }
            }
            do {
                let file = try AVAudioFile(forReading: directory.appendingPathComponent("speech-check.aiff"))
                while file.framePosition < file.length {
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                    try file.read(into: buffer)
                    request.append(buffer)
                }
                request.endAudio()
                try? await Task.sleep(for: .seconds(15))
            } catch { report["fixtureReadError"] = error.localizedDescription }
            task.cancel()
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("speech-check.json"), options: .atomic)
        }
    }
    #endif
    private func checkAudioOnDevice() async {
        guard !didCheckAudio, !busy else { return }
        didCheckAudio = true; connecting = true; status = "正在检查声音…"
        var report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date())]
        defer {
            voiceInput.stop()
            webView.evaluateJavaScript("window.stopLocalAudioCheck?.(); void(0)", completionHandler: nil)
            connecting = false; status = "房间已就绪"
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("audio-check.json")
                try? data.write(to: file, options: .atomic)
            }
        }
        do {
            try voiceInput.prepare()
            try await Task.sleep(for: .seconds(3))
            reportAudio(["audioCheck": "beforePlayback", "healthy": voiceInput.captureIsHealthy])
            report["beforePlayback"] = voiceInput.captureIsHealthy
            try await webView.evaluateJavaScript("window.startLocalAudioCheck(); void(0)")
            try await Task.sleep(for: .seconds(6))
            reportAudio(["audioCheck": "duringPlayback", "healthy": voiceInput.captureIsHealthy])
            report["duringPlayback"] = voiceInput.captureIsHealthy
            voiceInput.simulateRouteReset()
            try await Task.sleep(for: .seconds(3))
            reportAudio(["audioCheck": "afterForcedReset", "healthy": voiceInput.captureIsHealthy])
            report["afterForcedReset"] = voiceInput.captureIsHealthy
        } catch { report["error"] = error.localizedDescription; reportAudio(["audioCheck": "failed", "message": error.localizedDescription]) }
    }
    #endif

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        #if targetEnvironment(simulator)
        // WebKit defaults to synthetic capture in Simulator. This SPI is excluded from device builds.
        if config.preferences.responds(to: NSSelectorFromString("_setMockCaptureDevicesEnabled:")) {
            config.preferences.setValue(false, forKey: "mockCaptureDevicesEnabled")
        }
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        camera.onError = { [weak self] message in self?.error = message }
        voiceInput.onBands = { [weak self] bands in self?.micBands = bands }
        voiceInput.onLevel = { [weak self] level in
            guard let self else { return }
            self.micLevel = level
        }
        voiceInput.onListening = { [weak self] value in
            self?.listening = value
            self?.webView.evaluateJavaScript("diagnostic('rtc', {nativeSpeech: 'listening', active: \(value)}); void(0)", completionHandler: nil)
        }
        voiceInput.configureSession = { [weak self] in try self?.configureAudio() }
        voiceInput.onDiagnostic = { [weak self] detail in self?.reportAudio(detail) }
        voiceInput.onUtterance = { [weak self] words in self?.send(words) }
        voiceInput.onError = { [weak self] message in self?.error = message; self?.endCall() }
        if let data = try? Data(contentsOf: Companion.directory.appendingPathComponent("characters.json")), let saved = try? JSONDecoder().decode([Companion].self, from: data) { customCharacters = saved }
        name = UserDefaults.standard.string(forKey: "name." + selectedID) ?? name
        persona = UserDefaults.standard.string(forKey: "persona." + selectedID) ?? persona
        voice = UserDefaults.standard.string(forKey: "voice." + selectedID) ?? voice
        bridge = RoomBridge(owner: self)
        config.userContentController.add(bridge, name: "room")
        webView.uiDelegate = bridge
        webView.navigationDelegate = bridge
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        Task { await DeviceConnection.load(webView) }
        Task { await checkService() }
        #if DEBUG
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--check-characters") { checkCharacters() }
        if ProcessInfo.processInfo.arguments.contains("--check-speech") { Task { await checkSpeechOnSimulator() } }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--check-media") { Task { await checkMediaOnDevice() } }
        if ProcessInfo.processInfo.arguments.contains("--check-network") { Task { await checkNetworkOnDevice() } }
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    private func checkCharacters() {
        var report: [String: Any] = [:]
        do {
            let initial = characters.count
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32)) }
            try addCharacter(name: "新增验证", scene: "测试", picture: picture, voice: "Serena")
            let added = customCharacters.last!
            let saved = try JSONDecoder().decode([Companion].self, from: Data(contentsOf: Companion.directory.appendingPathComponent("characters.json")))
            report["addedAndSelected"] = characters.count == initial + 1 && selectedID == added.id
            report["persisted"] = saved.contains { $0.id == added.id } && FileManager.default.fileExists(atPath: Companion.directory.appendingPathComponent(added.imagePath!).path)
            try deleteCharacter(added)
            report["deletedAndFallback"] = characters.count == initial && selectedID == Companion.all.first!.id
            report["imageRemoved"] = !FileManager.default.fileExists(atPath: Companion.directory.appendingPathComponent(added.imagePath!).path)
            try deleteCharacter(Companion.all.first!)
            report["defaultProtected"] = characters.contains { $0.id == Companion.all.first!.id }
            let draft = CharacterDraft()
            if draft.image == nil {
                let id = UUID().uuidString
                draft.name = "任务恢复验证"; draft.image = picture; draft.requestID = id
                try draft.archiveCurrent()
                let restored = CharacterDraft()
                report["pendingArchived"] = restored.savedTasks.contains(id) && restored.image == nil
                restored.restoreTask(id)
                report["pendingRestored"] = restored.requestID == id && restored.image != nil
                restored.finish()
            }
        } catch { report["error"] = error.localizedDescription }
        let destination = Companion.directory.appendingPathComponent("character-check.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }
    #endif

    private func reportAudio(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail) else { return }
        let json = String(decoding: data, as: UTF8.self)
        webView.evaluateJavaScript("diagnostic('rtc', \(json)); void(0)", completionHandler: nil)
    }

    func refreshConnection() {
        guard !busy else { return }
        Task {
            await checkService()
            if !pageReady { await DeviceConnection.load(webView) }
        }
    }

    func checkService() async {
        guard !checkingService else { return }
        checkingService = true
        defer { checkingService = false }
        do {
            var request = DeviceConnection.request("/health")
            request.timeoutInterval = 10
            let (data, http) = try await DeviceConnection.session.data(for: request)
            guard (http as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            serviceReady = response?["has_api_key"] as? Bool == true
            if !busy { status = serviceReady ? "房间已就绪" : "请配置服务密钥" }
        } catch { serviceReady = false; status = "通话服务尚未连接" }
    }

    func startCall() {
        guard !busy else { return }
        voicePreview.stop(); error = nil
        guard serviceReady, pageReady else {
            #if targetEnvironment(simulator)
            error = "本机服务尚未就绪。请先运行项目中的启动 Demo.command。"
            #else
            error = "通话服务暂时未连接，请确认手机网络正常后重试。"
            #endif
            refreshConnection()
            return
        }
        let token = UUID(); operation = token
        #if !targetEnvironment(simulator)
        muted = false
        speaker = true
        #endif
        connecting = true; status = "请求麦克风权限…"; liveID = ""
        remoteSpeaking = false; awaitingReply = false
        Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard operation == token, connecting else { return }
            guard allowed else { connecting = false; error = "需要麦克风权限才能进行语音对话，请在系统设置中允许。"; return }
            do {
                let speechAllowed = await VoiceInput.authorize()
                guard operation == token, connecting else { return }
                guard speechAllowed else { connecting = false; error = "需要语音识别权限才能听懂你的话，请在系统设置中允许。"; return }
            }
            do { try configureAudio() } catch { connecting = false; self.error = "无法启用通话音频：" + error.localizedDescription; return }
            do { try voiceInput.prepare() }
            catch { connecting = false; self.error = error.localizedDescription; return }
            #if targetEnvironment(simulator)
            status = "正在准备语音识别…"
            do { try await voiceInput.preflightRecognition() }
            catch { voiceInput.stop(); connecting = false; self.error = "语音识别未就绪，尚未创建通话：" + error.localizedDescription; return }
            guard operation == token, connecting else { voiceInput.stop(); return }
            #endif
            guard let data = image.jpegData(compressionQuality: 0.85) else { voiceInput.stop(); connecting = false; error = "人物图片无法读取"; return }
            let payload: [String: Any] = ["call_mode": "video", "model": "vidu-s2", "avatar": ["name": name, "voice": voice, "persona": persona, "persona_enhance": false, "image_uri": "data:image/jpeg;base64," + data.base64EncodedString()]]
            do {
                let json = try JSONSerialization.data(withJSONObject: payload)
                let text = String(decoding: json, as: UTF8.self)
                try await webView.evaluateJavaScript("window.startCall(\(text), { nativeSpeech: true }); void(0)")
            } catch { self.error = error.localizedDescription; endCall() }
        }
    }

    func endCall() {
        voicePreview.stop()
        camera.stop()
        voiceInput.stop(); replyTimeout?.cancel(); replyTimeout = nil
        awaitingReply = false; remoteSpeaking = false
        micLevel = 0
        stopMicTest()
        guard busy else { return }
        ending = true
        operation = UUID()
        webView.evaluateJavaScript("window.endCall(); void(0)", completionHandler: nil)
        connecting = false; connected = false; hasVideo = false; muted = false; startDate = nil
        status = "正在结束通话…"
    }
    func toggleMute() {
        guard connected else { return }
        muted.toggle(); updateListening()
        if muted { micLevel = 0 }
    }
    private func updateListening() {
        voiceInput.setListening(connected && !muted && !remoteSpeaking && !awaitingReply)
    }
    func send(_ text: String) {
        guard connected, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else { return }
        awaitingReply = true; updateListening()
        let token = operation
        webView.evaluateJavaScript("window.sendText(\(json))") { [weak self] result, error in
            guard let self, self.operation == token, self.connected else { return }
            if error != nil || result as? Bool != true {
                self.error = "这句话没有发送成功，请重新说一次。"
                self.awaitingReply = false; self.updateListening()
            }
        }
        replyTimeout?.cancel()
        replyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.operation == token, self.connected, self.awaitingReply else { return }
            self.awaitingReply = false
            self.error = "暂时还没有收到回复，可以再说一次。"
            self.updateListening()
        }
    }
    func select(_ companion: Companion) {
        guard !busy else { return }
        voicePreview.stop()
        selectedID = companion.id; name = displayName(for: companion); voice = UserDefaults.standard.string(forKey: "voice." + companion.id) ?? companion.voice
        persona = UserDefaults.standard.string(forKey: "persona." + companion.id) ?? (companion.persona + Companion.conversation)
        image = companion.portrait
        voiceReason = "已搭配角色音色，可随时调整"; error = nil
    }
    func addCharacter(name: String, scene: String, picture: UIImage, voice: String) throws {
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: Companion.directory, withIntermediateDirectories: true)
        guard let data = picture.jpegData(compressionQuality: 0.9) else { throw NSError(domain: "CharacterImage", code: 1) }
        let filename = id + ".jpg"
        try data.write(to: Companion.directory.appendingPathComponent(filename), options: .atomic)
        let character = Companion(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新朋友" : name, resource: "", tagline: scene, voice: voice, persona: "你叫\(name)，是一位自然友好的虚拟角色，身处\(scene)。", imagePath: filename, scene: scene)
        let updated = customCharacters + [character]
        try JSONEncoder().encode(updated).write(to: Companion.directory.appendingPathComponent("characters.json"), options: .atomic)
        customCharacters = updated; select(character)
    }
    func displayName(for companion: Companion) -> String { UserDefaults.standard.string(forKey: "name." + companion.id) ?? companion.name }
    func saveProfile() {
        UserDefaults.standard.set(name, forKey: "name." + selectedID)
        UserDefaults.standard.set(persona, forKey: "persona." + selectedID)
    }
    func saveVoice() { UserDefaults.standard.set(voice, forKey: "voice." + selectedID) }
    private func configureAudio() throws {
        let session = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        // The simulator still requires an active recording session to expose
        // the Mac input selected in Simulator's I/O menu.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        #else
        // Keep the proven device configuration: native capture and WebKit
        // playback must coexist without interrupting each other's session.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: speaker ? [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers] : [.allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        #endif
    }
    func toggleSpeaker() {
        speaker.toggle()
        #if targetEnvironment(simulator)
        webView.evaluateJavaScript("window.setSpeaker(\(speaker)); void(0)", completionHandler: nil)
        #else
        do { try configureAudio(); webView.evaluateJavaScript("window.setSpeaker(true); void(0)", completionHandler: nil) }
        catch { self.error = "切换扬声器失败：" + error.localizedDescription }
        #endif
    }
    func testMic() {
        guard !busy, pageReady else { return }
        Task { if await AVAudioApplication.requestRecordPermission() {
            webView.evaluateJavaScript("window.testMicrophone(); void(0)", completionHandler: nil)
        } else { error = "请在系统设置中允许麦克风权限" } }
    }
    func stopMicTest() { webView.evaluateJavaScript("window.stopMicTest?.(); void(0)", completionHandler: nil) }
    func importImage(_ data: Data) async {
        guard let newImage = UIImage(data: data), !busy else { return }
        image = newImage; selectedID = UUID().uuidString; name = "新朋友"; persona = "你是一位友好自然的虚拟角色。" + Companion.conversation
        matchingVoice = true; voiceReason = "正在根据图片风格匹配音色…"
        defer { matchingVoice = false }
        do {
            guard let jpeg = newImage.jpegData(compressionQuality: 0.8) else { return }
            var req = DeviceConnection.request("/api/avatar/recommend-voice")
            req.httpMethod = "POST"; req.timeoutInterval = 180; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["image_uri": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
            let (data, response) = try await DeviceConnection.session.data(for: req)
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200, let matched = result?["voice"] as? String else { throw NSError(domain: "VoiceMatch", code: 1) }
            voice = matched; voiceReason = result?["reason"] as? String ?? "已匹配建议音色"; saveVoice()
        } catch { voiceReason = "自动匹配暂时不可用，请手动选择音色" }
    }
    func event(_ payload: [String: Any]) {
        switch payload["event"] as? String {
        case "ready":
            pageReady = true; Task { await checkService() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--check-audio") { Task { await checkAudioOnDevice() } }
            if ProcessInfo.processInfo.arguments.contains("--check-network") { Task { await checkNetworkOnDevice() } }
            #endif
        case "micLevel": if micTesting { micLevel = payload["level"] as? Double ?? 0 }
        case "micTest": micTesting = payload["active"] as? Bool ?? false; if !micTesting { micLevel = 0 }
        case "status": if busy { status = payload["message"] as? String ?? status }
        case "session": liveID = payload["id"] as? String ?? ""
        case "connected": connecting = false; connected = true; startDate = Date(); updateListening()
        case "remoteSpeaking":
            remoteSpeaking = payload["active"] as? Bool ?? false
            if remoteSpeaking { awaitingReply = false; replyTimeout?.cancel() }
            updateListening()
        case "textSent": error = nil
        case "textFailed": awaitingReply = false; replyTimeout?.cancel(); updateListening()
        case "video": hasVideo = true; error = nil
        case "muted": muted = payload["value"] as? Bool ?? false
        case "error", "notice": error = payload["message"] as? String
        case "ended":
            camera.stop(); voiceInput.stop(); replyTimeout?.cancel(); micLevel = 0; ending = false; connecting = false; connected = false; hasVideo = false; muted = false; startDate = nil; status = "通话已结束"
            if payload["reloadRequired"] as? Bool == true { pageReady = false; webView.reload() }
        default: break
        }
    }
}

final class RoomBridge: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    weak var owner: RoomModel?
    init(owner: RoomModel) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in owner?.event(body) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == DeviceConnection.host && type == .microphone ? .grant : .deny)
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        DeviceConnection.respond(to: challenge, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in owner?.pageReady = false; owner?.status = "通话服务尚未连接" }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in owner?.endCall(); owner?.pageReady = false; webView.reload() }
    }
}

struct LiveSurface: UIViewRepresentable {
    @ObservedObject var room: RoomModel
    func makeUIView(context: Context) -> WKWebView { room.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
