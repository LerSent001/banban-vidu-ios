import SwiftUI
import PhotosUI

@MainActor
final class CharacterDraft: ObservableObject {
    @Published var name = ""
    @Published var poseID = "natural"
    @Published var scene = "温暖的卧室，米色床品，柔和的落地灯，安静舒适"
    @Published var image: UIImage?
    @Published var generated: UIImage?
    @Published var voice = "Serena"
    @Published var voiceReason = "上传人物图片后自动搭配"
    @Published var working = false
    @Published var matching = false
    @Published var status = ""
    @Published var error: String?
    @Published var savedTasks: [String] = []
    var requestID: String?
    private var revision = UUID()
    private let draftFile = Companion.directory.appendingPathComponent("pending-draft.json")
    var canEdit: Bool { !working && requestID == nil }
    init() { loadDraft(); refreshSavedTasks() }
    private var archiveDirectory: URL { Companion.directory.appendingPathComponent("PendingScenes", isDirectory: true) }
    private let draftFiles = ["pending-draft.json", "pending-source.jpg", "pending-result.jpg"]
    private func refreshSavedTasks() {
        savedTasks = ((try? FileManager.default.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)) ?? []).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pending-draft.json").path) }.map(\.lastPathComponent).sorted()
    }
    func archiveCurrent() throws {
        guard let id = requestID else { finish(); return }
        try saveDraft()
        let directory = archiveDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in draftFiles {
            let source = Companion.directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) { try Data(contentsOf: source).write(to: directory.appendingPathComponent(file), options: .atomic) }
        }
        finish(); requestID = nil; image = nil; generated = nil; status = ""; error = nil
        refreshSavedTasks()
    }
    func restoreTask(_ id: String) {
        do {
            let directory = archiveDirectory.appendingPathComponent(id)
            for file in draftFiles {
                let source = directory.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: source.path) { try Data(contentsOf: source).write(to: Companion.directory.appendingPathComponent(file), options: .atomic) }
            }
            loadDraft()
            try FileManager.default.removeItem(at: directory)
            refreshSavedTasks()
        } catch { self.error = "恢复失败：" + error.localizedDescription }
    }
    private func loadDraft() {
        if let data = try? Data(contentsOf: draftFile), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            poseID = saved["pose_id"] ?? "natural"
            name = saved["name"] ?? ""; scene = saved["scene"] ?? scene; voice = saved["voice"] ?? voice; requestID = saved["request_id"].flatMap { $0.isEmpty ? nil : $0 }
            image = UIImage(contentsOfFile: Companion.directory.appendingPathComponent("pending-source.jpg").path)
            generated = UIImage(contentsOfFile: Companion.directory.appendingPathComponent("pending-result.jpg").path)
            status = generated == nil ? "有一个已提交的场景任务，可继续获取" : "场景已生成，可以加入列表"
        }
    }
    func upload(_ data: Data) async {
        guard canEdit, let photo = UIImage(data: data) else { return }
        let token = UUID(); revision = token
        let previousVoice = voice
        image = photo; generated = nil; error = nil; matching = true; voiceReason = "正在匹配适合的音色…"
        defer { if revision == token { matching = false } }
        do {
            let result = try await api("/api/avatar/recommend-voice", body: ["image_uri": uri(photo)])
            guard revision == token else { return }
            if voice == previousVoice { voice = result["voice"] as? String ?? "Serena" }; voiceReason = result["reason"] as? String ?? "已自动匹配，可手动调整"
        } catch { if revision == token { voiceReason = "自动匹配暂不可用，可手动选择" } }
    }
    private func uri(_ photo: UIImage) -> String {
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(photo.size.width, photo.size.height))
        let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let resized = renderer.image { _ in photo.draw(in: CGRect(origin: .zero, size: size)) }
        return "data:image/jpeg;base64," + (resized.jpegData(compressionQuality: 0.88)?.base64EncodedString() ?? "")
    }
    private func api(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = DeviceConnection.request(path)
        req.timeoutInterval = path.contains("recommend-voice") ? 12 : 180
        if let body { req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await DeviceConnection.session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Scene", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: json["error"] as? String ?? "连接失败，请稍后继续获取"]) }
        return json
    }
    private func saveDraft() throws {
        try FileManager.default.createDirectory(at: Companion.directory, withIntermediateDirectories: true)
        try image?.jpegData(compressionQuality: 0.9)?.write(to: Companion.directory.appendingPathComponent("pending-source.jpg"), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["name": name, "scene": scene, "pose_id": poseID, "voice": voice, "request_id": requestID ?? ""]).write(to: draftFile, options: .atomic)
    }
    func generate() async {
        guard !working, let image, !scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        working = true; error = nil; status = requestID == nil ? "正在提交场景定制…" : "正在获取已有场景…"
        defer { working = false }
        do {
            var result: [String: Any]
            if let id = requestID {
                do { result = try await api("/api/avatar/scenes/" + id) }
                catch let failure as NSError where failure.code == 404 {
                    // Retry the SAME idempotency key, never create a replacement paid task.
                    result = try await api("/api/avatar/scenes", body: ["request_id": id, "scene": scene, "pose_id": poseID, "image_uri": uri(image)])
                }
            }
            else {
                requestID = UUID().uuidString
                try? FileManager.default.removeItem(at: Companion.directory.appendingPathComponent("pending-result.jpg"))
                try saveDraft()
                result = try await api("/api/avatar/scenes", body: ["request_id": requestID!, "scene": scene, "pose_id": poseID, "image_uri": uri(image)])
            }
            let deadline = Date().addingTimeInterval(600)
            while true {
                let state = result["state"] as? String ?? "unknown"
                if state == "success", let urlString = result["image_url"] as? String, let url = URL(string: urlString) {
                    status = "正在保存场景图…"
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Scene", code: 2, userInfo: [NSLocalizedDescriptionKey: "场景图片下载失败，可继续获取"]) }
                    guard let picture = UIImage(data: data) else { throw NSError(domain: "Scene", code: 2, userInfo: [NSLocalizedDescriptionKey: "场景图片下载失败，可继续获取"]) }
                    try picture.jpegData(compressionQuality: 0.9)?.write(to: Companion.directory.appendingPathComponent("pending-result.jpg"), options: .atomic)
                    generated = picture
                    status = "场景已生成，确认后加入角色列表"; return
                }
                if state == "success" { throw NSError(domain: "Scene", code: 2, userInfo: [NSLocalizedDescriptionKey: "场景已完成，但图片暂不可用，请稍后继续获取"]) }
                if state == "failed" { requestID = nil; try? FileManager.default.removeItem(at: draftFile); throw NSError(domain: "Scene", code: 3, userInfo: [NSLocalizedDescriptionKey: result["error"] as? String ?? "场景生成失败，可修改后重试"]) }
                if state == "unknown" || state == "submitting" { throw NSError(domain: "Scene", code: 4, userInfo: [NSLocalizedDescriptionKey: "提交结果尚未确认，已保留任务记录，请勿重复创建。"]) }
                guard Date() < deadline else { status = "场景仍在处理中，稍后可继续获取"; return }
                status = state == "processing" ? "正在定制场景…" : "场景正在排队…"
                try await Task.sleep(for: .seconds(3))
                result = try await api("/api/avatar/scenes/" + requestID!)
            }
        } catch {
            let failure = error as NSError
            if failure.domain == "Scene" && [400, 401, 403, 413, 422].contains(failure.code) {
                requestID = nil; try? saveDraft()
            }
            self.error = (error as? URLError)?.code == .timedOut ? "连接超时，任务已保留，请检查网络后继续获取" : error.localizedDescription
        }
    }
    func addGenerated(to room: RoomModel) throws {
        guard let picture = generated else { throw NSError(domain: "Scene", code: 5, userInfo: [NSLocalizedDescriptionKey: "请等待场景生成完成"]) }
        try room.addCharacter(name: name, scene: scene, picture: picture, voice: voice)
        finish()
    }
    func finish() {
        for file in ["pending-draft.json", "pending-source.jpg", "pending-result.jpg"] { try? FileManager.default.removeItem(at: Companion.directory.appendingPathComponent(file)) }
    }
}

@MainActor
struct NewCharacterView: View {
    @EnvironmentObject private var room: RoomModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = CharacterDraft()
    @State private var selected: PhotosPickerItem?
    let onSaved: () -> Void
    private let scenes = [("暖光卧室", "温暖的卧室，米色床品，柔和的落地灯，安静舒适"), ("日落书房", "日落时分的书房，木质书架，窗外粉紫色天空，温暖台灯"), ("雨夜公寓", "雨夜的现代公寓，落地窗外有雨滴和城市灯光，温暖室内灯光")]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if draft.image == nil && !draft.savedTasks.isEmpty {
                        ForEach(draft.savedTasks, id: \.self) { id in
                            Button("恢复未完成场景 · " + String(id.prefix(8))) { draft.restoreTask(id) }
                        }
                    }
                    if draft.requestID != nil {
                        Button("保留此任务，新增其他角色") {
                            do { try draft.archiveCurrent(); selected = nil } catch { draft.error = "保存任务失败：" + error.localizedDescription }
                        }.disabled(draft.working)
                    }
                    PhotosPicker(selection: $selected, matching: .images) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.07))
                            if let picture = draft.generated ?? draft.image {
                                Image(uiImage: picture).resizable().scaledToFit().frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                VStack(spacing: 12) { Image(systemName: "person.crop.rectangle.badge.plus").font(.system(size: 32)); Text("上传人物图片").font(.headline); Text("选择清晰的单人照或角色图").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.frame(maxWidth: .infinity).frame(height: 260)
                    }.buttonStyle(.plain).disabled(!draft.canEdit)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("角色名字").font(.headline)
                        TextField("给新朋友起个名字", text: $draft.name).padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("正面坐姿").font(.headline)
                        Text("保留人物外貌与衣着，统一正面平视。侧面照片也会重新安排姿势；脸部越清楚，还原越可靠。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("坐姿风格", selection: Binding(get: {
                            ScenePose.all.first(where: { $0.id == draft.poseID })?.group ?? "通用"
                        }, set: { group in
                            draft.poseID = ScenePose.all.first(where: { $0.group == group })?.id ?? "natural"
                        })) {
                            Text("自然").tag("通用"); Text("女生").tag("女生"); Text("男生").tag("男生")
                        }.pickerStyle(.segmented)
                        ForEach(ScenePose.all.filter { $0.group == (ScenePose.all.first(where: { $0.id == draft.poseID })?.group ?? "通用") }) { pose in
                            Button { draft.poseID = pose.id } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: draft.poseID == pose.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(draft.poseID == pose.id ? Color.green : Color.secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(pose.name).font(.subheadline).foregroundStyle(.white)
                                        Text(pose.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }.disabled(!draft.canEdit)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("定制场景").font(.headline)
                        HStack(spacing: 8) {
                            ForEach(scenes, id: \.0) { scene in Button(scene.0) { draft.scene = scene.1 }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9).background(draft.scene == scene.1 ? .white.opacity(0.22) : .white.opacity(0.07), in: Capsule()) }
                        }
                        TextField("描述你希望人物待着的地方…", text: $draft.scene, axis: .vertical).lineLimit(3...5).padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }.disabled(!draft.canEdit)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("角色音色").font(.headline); Spacer(); if draft.matching { ProgressView() } }
                        NavigationLink {
                            VoiceLibrary(selection: $draft.voice, preview: room.voicePreview)
                        } label: {
                            HStack {
                                Text(CompanionVoice.all.first(where: { $0.id == draft.voice })?.name ?? draft.voice)
                                Spacer(); Text("选择与试听"); Image(systemName: "chevron.right")
                            }.font(.subheadline)
                        }.tint(.white).disabled(room.busy)
                        Text(draft.voiceReason).font(.caption).foregroundStyle(.secondary)
                    }
                    if !draft.status.isEmpty { HStack { if draft.working { ProgressView() }; Text(draft.status).font(.subheadline) } }
                    if let error = draft.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if draft.image != nil && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("请先填写角色名字").font(.caption).foregroundStyle(.orange)
                    }
                    if draft.generated == nil {
                    Button("使用原图加入角色列表") {
                        guard let picture = draft.image else { return }
                        do {
                            // Archive before saving the character, so an archive error cannot create duplicates.
                            if draft.requestID != nil { try draft.archiveCurrent() }
                            try room.addCharacter(name: draft.name, scene: "参考图中的场景", picture: picture, voice: draft.voice)
                            draft.finish()
                            dismiss(); onSaved()
                        } catch { draft.error = "保存失败：" + error.localizedDescription }
                    }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                        .disabled(draft.image == nil || draft.working || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("可直接使用原图，也可先生成专属场景。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        if draft.generated != nil {
                            do { try draft.addGenerated(to: room); dismiss(); onSaved() } catch { draft.error = "保存失败：" + error.localizedDescription }
                        } else { Task { await draft.generate() } }
                    } label: {
                        Text(draft.generated != nil ? "加入角色列表" : draft.requestID != nil ? "继续获取场景" : "生成专属场景").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(17).background(.white, in: Capsule())
                    }.disabled(draft.image == nil || draft.working || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).opacity(draft.image == nil || draft.working ? 0.45 : 1)
                }.padding(20)
            }.navigationTitle("新增角色").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(draft.working) } }
                .interactiveDismissDisabled(draft.working)
                .onChange(of: selected) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { await draft.upload(data) } } }
        }
    }
}
