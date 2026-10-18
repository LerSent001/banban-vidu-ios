import SwiftUI
import AVFoundation

@MainActor
final class VoicePreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    @Published private(set) var loadingID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message = "点击播放，听听声音再选择"
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var interruption: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    override init() {
        super.init()
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop(); self?.message = "试听已暂停，点击可重新播放" }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.stop() }
        }
    }
    func toggle(_ voice: CompanionVoice) {
        if playingID == voice.id || loadingID == voice.id { stop(); return }
        stop(); error = nil; loadingID = voice.id; message = "正在准备「\(voice.name)」…"
        do {
            guard let url = Bundle.main.url(forResource: voice.sampleFile, withExtension: nil, subdirectory: "VoiceSamples") else {
                throw NSError(domain: "VoicePreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有找到这段音色样音，请重新安装最新版本。"])
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.delegate = self; audio.volume = 1
            audio.prepareToPlay()
            guard audio.play() else { throw NSError(domain: "VoicePreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "声音播放失败，请检查当前音频输出后重试。"]) }
            player = audio; playingID = voice.id; loadingID = nil
            message = "正在试听「\(voice.name)」"
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                }
            }
        } catch {
            stop(); self.error = error.localizedDescription; message = "试听未能播放，点击可重试"
        }
    }
    #if DEBUG
    var diagnostic: [String: Any] {
        ["id": playingID ?? "", "playing": player?.isPlaying ?? false,
         "time": player?.currentTime ?? 0, "duration": player?.duration ?? 0,
         "outputVolume": AVAudioSession.sharedInstance().outputVolume,
         "outputs": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue },
         "error": error ?? ""]
    }
    #endif
    func stop() {
        let wasActive = player != nil
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playingID = nil; loadingID = nil; progress = 0
        message = "点击播放，听听声音再选择"
        if wasActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stop(); self.message = flag ? "试听结束，可以换一个声音比较" : "试听中断，点击可重新播放"
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stop(); self.error = "样音解码失败，请重新安装最新版本。"
        }
    }
    deinit {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        timer?.invalidate()
    }
}

struct VoiceLibrary: View {
    @Binding var selection: String
    @ObservedObject var preview: VoicePreview
    @State private var gender = "女声"
    var body: some View {
        List {
            Section {
                Picker("声线分类", selection: $gender) {
                    Text("女声 · 12").tag("女声")
                    Text("男声 · 12").tag("男声")
                }.pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.message).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voicePreviewStatus")
                    if preview.playingID != nil { ProgressView(value: preview.progress).tint(.white) }
                    if let error = preview.error { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
            Section {
                ForEach(CompanionVoice.all.filter { $0.gender == gender }) { voice in
                    HStack(spacing: 12) {
                        Button { selection = voice.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selection == voice.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection == voice.id ? Color.green : Color.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(voice.name).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                                    Text(voice.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("选用" + voice.name)
                        Button { preview.toggle(voice) } label: {
                            ZStack {
                                Circle().fill(.white.opacity(0.08))
                                if preview.loadingID == voice.id { ProgressView() }
                                else { Image(systemName: preview.playingID == voice.id ? "stop.fill" : "play.fill").font(.system(size: 14)) }
                            }.frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel((preview.playingID == voice.id ? "停止试听" : "试听") + voice.name)
                            .accessibilityIdentifier("previewVoice-" + voice.id)
                    }.padding(.vertical, 3)
                }
            } footer: {
                Text("播放按钮只试听，点击名称为角色选用。样音来自通义官方，文案与语言可能不同；实际通话的语气会随内容变化。御姐、男主等标签用于风格参考，以听感为准。")
            }
        }.navigationTitle("选择与试听").navigationBarTitleDisplayMode(.inline)
            .onAppear { gender = CompanionVoice.all.first(where: { $0.id == selection })?.gender ?? "女声" }
            .onDisappear { preview.stop() }
    }
}
