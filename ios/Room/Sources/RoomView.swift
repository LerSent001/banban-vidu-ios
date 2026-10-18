import SwiftUI

struct RoomView: View {
    @EnvironmentObject private var room: RoomModel
    @State private var characters = false
    #if DEBUG
    @State private var settings = ProcessInfo.processInfo.arguments.contains("--show-settings")
    #else
    @State private var settings = false
    #endif
    @ObservedObject var camera: FrontCamera

    init(camera: FrontCamera) { self.camera = camera }
    var body: some View {
        ZStack {
            CallStage(room: room, camera: room.camera).ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        control("line.3.horizontal", label: "切换角色") { characters = true }.disabled(room.busy)
                        Spacer()
                        Button { camera.toggle() } label: {
                            ZStack {
                                Image(systemName: camera.enabled ? "video.fill" : "video.slash")
                                    .font(.system(size: 17, weight: .medium)).opacity(camera.starting ? 0 : 1)
                                if camera.starting { ProgressView().tint(.white) }
                            }.frame(width: 44, height: 44)
                                .background(camera.enabled ? Color.white.opacity(0.28) : Color.white.opacity(0.12), in: Circle())
                        }.accessibilityLabel(camera.enabled ? "关闭我的画面" : "开启我的画面")
                            .accessibilityIdentifier("toggleCameraButton").padding(.trailing, 12)
                        control("ellipsis", label: "角色设置") { settings = true }
                    }
                    Spacer()
                    if let error = room.error {
                        HStack(alignment: .top) {
                            Text(error).font(.system(size: 12)).lineSpacing(3)
                            Spacer(minLength: 8)
                            Button { room.error = nil } label: { Image(systemName: "xmark") }
                        }.padding(14).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16)).padding(.bottom, 12)
                    }
                    if room.connecting || room.ending {
                        HStack(spacing: 8) { ProgressView().tint(.white); Text(room.status).font(.system(size: 12)) }.padding(12).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 14)
                    }
                    if room.connected {
                        HStack(spacing: 3) {
                            ForEach(0..<23, id: \.self) { index in
                                Capsule().fill(.white.opacity(room.listening ? 0.95 : 0.55))
                                    .frame(width: 3, height: 4 + (room.listening ? room.micBands[abs(index - 11)] * 29 * pow(1 - Double(abs(index - 11)) / 13, 0.55) : 0))
                            }
                        }.frame(height: 30).padding(.vertical, 9)
                            .animation(.interpolatingSpring(stiffness: 280, damping: 22), value: room.micBands)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(room.muted ? "麦克风已静音" : room.listening ? "正在接收语音" : "等待人物回复")
                            .padding(.bottom, 16)
                    }
                    if room.connected, let date = room.startDate {
                        Text(date, style: .timer).font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 4).padding(.bottom, 24).accessibilityLabel("通话时长")
                    }
                    HStack(alignment: .top, spacing: 38) {
                        if room.busy {
                            callControl(room.muted ? "mic.slash.fill" : "mic.fill", label: room.muted ? "已静音" : "麦克风", color: .white.opacity(0.18)) { room.toggleMute() }.disabled(!room.connected)
                        }
                        callControl(room.busy ? "phone.down.fill" : "phone.fill", label: room.busy ? "挂断" : "开始通话", color: room.busy ? Color(red: 0.92, green: 0.22, blue: 0.26) : Color(red: 0.14, green: 0.75, blue: 0.37)) {
                            if room.busy { room.endCall() } else { room.startCall() }
                        }.accessibilityIdentifier(room.busy ? "endCallButton" : "startCallButton").disabled(room.ending || room.matchingVoice)
                        if room.busy {
                            callControl(room.speaker ? "speaker.wave.2.fill" : "speaker.slash.fill", label: room.speaker ? "扬声器" : "听筒", color: .white.opacity(0.18)) { room.toggleSpeaker() }
                        }
                    }.padding(.bottom, 24)
                }.foregroundStyle(.white).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
        }.preferredColorScheme(.dark)
        .sheet(isPresented: $characters) { CharacterPicker().environmentObject(room).presentationDetents([.height(340), .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $settings) { CharacterSettings().environmentObject(room).presentationDetents([.large]) }
    }
    private func callControl(_ icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 25, weight: .medium)).frame(width: 68, height: 68).background(color, in: Circle())
                Text(label).font(.system(size: 12))
            }
        }.accessibilityLabel(label)
    }
    private func control(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle()) }.accessibilityLabel(label)
    }
}

// Keep both rendering surfaces mounted so swapping never recreates the RTC player.
private struct CallStage: View {
    @ObservedObject var room: RoomModel
    @ObservedObject var camera: FrontCamera
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dockRight = true
    @State private var verticalFraction: CGFloat = 0
    @GestureState private var dragTranslation = CGSize.zero
    private var windowAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)
    }
    var body: some View {
        GeometryReader { geometry in
            let full = geometry.size
            let mini = CGSize(width: 106, height: 158)
            let insetTop = max(geometry.safeAreaInsets.top, 54) + 68
            let minX = mini.width / 2 + 18
            let maxX = max(minX, full.width - minX)
            let minY = insetTop + mini.height / 2
            let maxY = max(minY, full.height - max(geometry.safeAreaInsets.bottom, 34) - 148 - mini.height / 2)
            let restingCenter = CGPoint(x: dockRight ? maxX : minX, y: minY + verticalFraction * (maxY - minY))
            let miniCenter = CGPoint(
                x: min(maxX, max(minX, restingCenter.x + dragTranslation.width)),
                y: min(maxY, max(minY, restingCenter.y + dragTranslation.height))
            )
            let center = CGPoint(x: full.width / 2, y: full.height / 2)
            let localLarge = camera.enabled && camera.expanded
            let avatarSize = localLarge ? mini : full
            let cameraSize = localLarge ? full : mini
            ZStack(alignment: .topLeading) {
                ZStack {
                    Color.black
                    Image(uiImage: room.image).resizable().scaledToFill()
                        .frame(width: avatarSize.width, height: avatarSize.height).clipped()
                    LiveSurface(room: room).opacity(room.hasVideo ? 1 : 0.001).allowsHitTesting(false)
                }.frame(width: avatarSize.width, height: avatarSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: localLarge ? 16 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(localLarge ? 0.3 : 0), lineWidth: 0.5))
                    .position(localLarge ? miniCenter : center).zIndex(localLarge ? 2 : 0)
                CameraSurface(camera: camera)
                    .frame(width: cameraSize.width, height: cameraSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: localLarge ? 0 : 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(localLarge ? 0 : 0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(localLarge ? 0 : 0.22), radius: 12, y: 5)
                    .scaleEffect(camera.enabled || reduceMotion ? 1 : 0.88)
                    .position(localLarge ? center : miniCenter)
                    .opacity(camera.enabled ? 1 : 0).allowsHitTesting(false).zIndex(localLarge ? 0 : 2)
                LinearGradient(stops: [.init(color: .black.opacity(0.22), location: 0), .init(color: .clear, location: 0.3), .init(color: .clear, location: 0.7), .init(color: .black.opacity(0.3), location: 1)], startPoint: .top, endPoint: .bottom)
                    .frame(width: full.width, height: full.height).allowsHitTesting(false).zIndex(1)
                if camera.enabled {
                    Color.clear.contentShape(RoundedRectangle(cornerRadius: 16))
                        .frame(width: mini.width, height: mini.height).position(miniCenter).zIndex(3)
                        .gesture(
                            DragGesture(minimumDistance: 8, coordinateSpace: .named("callStage"))
                                .updating($dragTranslation) { value, translation, _ in translation = value.translation }
                                .onEnded { value in
                                    let releasedX = restingCenter.x + value.translation.width
                                    let releasedY = min(maxY, max(minY, restingCenter.y + value.translation.height))
                                    dockRight = releasedX >= full.width / 2
                                    verticalFraction = maxY > minY ? (releasedY - minY) / (maxY - minY) : 0
                                }
                                .exclusively(before: TapGesture().onEnded { camera.swap() })
                        )
                        .accessibilityLabel(localLarge ? "将数字人切换到大画面" : "将我的画面切换到大画面")
                        .accessibilityHint("可拖动小窗，松手后自动贴边；轻点切换大小画面")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { camera.swap() }
                        .accessibilityIdentifier("swapVideoButton")
                }
            }
            .coordinateSpace(name: "callStage")
            .animation(dragTranslation == .zero ? windowAnimation : nil, value: miniCenter)
            .animation(windowAnimation, value: camera.enabled)
            .animation(windowAnimation, value: camera.expanded)
        }
    }
}

struct CharacterPicker: View {
    @EnvironmentObject private var room: RoomModel
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing = false
    @State private var deleting: Companion?
    @State private var deleteError: String?
    var body: some View {
        NavigationStack {
        VStack(spacing: 16) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), alignment: .leading, spacing: 16) {
                    ForEach(room.characters) { companion in
                        Button { if editing { if room.canDelete(companion) { deleting = companion } } else { room.select(companion); dismiss() } } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                GeometryReader { proxy in
                                    Image(uiImage: companion.portrait).renderingMode(.original).resizable().scaledToFill()
                                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                                }.frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(room.selectedID == companion.id ? .white : .clear, lineWidth: 2))
                                if editing { Text(room.canDelete(companion) ? "删除" : "默认角色 · 保留").font(.caption).foregroundStyle(room.canDelete(companion) ? .red : .secondary) }
                                Text(room.displayName(for: companion)).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("选择" + companion.name)
                    }
                }.padding(2)
            }.scrollIndicators(.hidden)
            Button { adding = true } label: {
                Label("新增角色", systemImage: "plus").font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 48).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityIdentifier("addCharacterButton")
        }.padding(.horizontal, 20).padding(.top, 0).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(editing ? "编辑角色" : "选择角色")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(editing ? "完成" : "编辑") { editing.toggle() }.disabled(room.busy) } }
            .alert("删除角色？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) {
                    if let companion = deleting { do { try room.deleteCharacter(companion) } catch { deleteError = error.localizedDescription } }
                    deleting = nil
                }
            } message: { Text("删除后将从本机角色列表移除。默认角色会一直保留。") }
            .alert("删除失败", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) { Button("好") { deleteError = nil } } message: { Text(deleteError ?? "") }
            .navigationBarTitleDisplayMode(.inline)
        }
            .sheet(isPresented: $adding) { NewCharacterView(onSaved: { dismiss() }).environmentObject(room) }
    }
}

struct CharacterSettings: View {
    @EnvironmentObject private var room: RoomModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("名字") {
                    HStack(spacing: 16) {
                        Image(uiImage: room.image).resizable().scaledToFill().frame(width: 48, height: 64).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                        TextField("角色名字", text: $room.name)
                    }.disabled(room.busy)
                }
                Section("人设") {
                    TextEditor(text: $room.persona).frame(minHeight: 190).font(.system(size: 15)).lineSpacing(5).disabled(room.busy)
                        .accessibilityLabel("编辑角色人设")
                }
                Section("声音") {
                    NavigationLink {
                        VoiceLibrary(selection: $room.voice, preview: room.voicePreview)
                            .onChange(of: room.voice) { _, _ in room.saveVoice() }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("选择与试听音色")
                            Text(CompanionVoice.all.first(where: { $0.id == room.voice })?.name ?? room.voice)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(room.busy)
                    Text("24 种声线 · 点击播放即可比较").font(.caption).foregroundStyle(.secondary)
                }
                Section("连接") {
                    HStack {
                        Text(room.serviceReady && room.pageReady ? "已连接，可以通话" : "尚未连接服务")
                        Spacer()
                        if room.checkingService { ProgressView() }
                    }
                    Button("重新检查连接") { room.refreshConnection() }
                        .disabled(room.busy || room.checkingService)
                    Text("请自行接入 Vidu 国内 API；本仓库不提供可用账号或公共服务。检查连接不会开始通话。").font(.caption).foregroundStyle(.secondary)
                }
                if let error = room.error { Section { Text(error).font(.caption).foregroundStyle(.orange) } }
            }.navigationTitle("角色设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { room.saveProfile(); dismiss() } } }
                .onChange(of: room.name) { _, _ in room.saveProfile() }
                .onChange(of: room.persona) { _, _ in room.saveProfile() }
        }
    }
}
