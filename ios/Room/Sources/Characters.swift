import SwiftUI

struct Companion: Identifiable, Codable {
    let id: String, name: String, resource: String, tagline: String, voice: String, persona: String
    var imagePath: String? = nil
    var scene: String? = nil
    var portrait: UIImage {
        if let imagePath, let image = UIImage(contentsOfFile: Self.directory.appendingPathComponent(imagePath).path) { return image }
        return UIImage(named: resource + ".png") ?? UIImage()
    }
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Characters", isDirectory: true) }
    static let all: [Companion] = [
        .init(id: "xia", name: "小夏", resource: "bedroom", tagline: "温柔随和 · 暖光卧室", voice: "Serena", persona: "你叫小夏，是一位25岁的虚拟角色，温暖自然，喜欢音乐与日常聊天，身处暖光卧室。"),
        .init(id: "yuki", name: "星野", resource: "yuki", tagline: "轻快俏皮 · 月色莲池", voice: "Momo", persona: "你叫星野，是一位25岁的二次元虚拟角色，活泼幽默，喜欢漫画、猫和有趣的小事。你坐在月色莲池旁的石凳上，正面看向镜头，双手自然放在腿上，保持参考图中的坐姿和镜头角度。"),
        .init(id: "lu", name: "陆川", resource: "luchuan-front-v2", tagline: "从容沉稳 · 夜间办公室", voice: "Ethan", persona: "你叫陆川，是一位28岁的男性二次元虚拟角色，成熟自信，从容沉稳，交流时温和真诚。你身处夜间办公室，戴着眼镜，穿着衬衫和领带，舒展地靠坐在沙发上，正面看向镜头。双腿自然分开，一手搭扶手，一手放在大腿上，保持参考图中的坐姿和镜头角度。")
    ]
    static let conversation = "用自然普通话交流，回答简短口语化，一次一到三句话，认真倾听，不要长篇说教。保持参考图中的外貌、衣着和场景。"
}
struct CompanionVoice: Identifiable, Decodable {
    let id: String, name: String, detail: String, gender: String, provider: String, sampleURL: String, sampleFile: String
    static let all: [CompanionVoice] = {
        guard let url = Bundle.main.url(forResource: "VoiceCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let voices = try? JSONDecoder().decode([CompanionVoice].self, from: data) else { return [] }
        return voices
    }()
}

struct ScenePose: Identifiable, Decodable {
    let id: String, group: String, name: String, detail: String
    static let all: [ScenePose] = {
        guard let url = Bundle.main.url(forResource: "ScenePoses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let poses = try? JSONDecoder().decode([ScenePose].self, from: data) else { return [] }
        return poses
    }()
}
