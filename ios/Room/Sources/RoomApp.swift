import SwiftUI

@main
struct RoomApp: App {
    @StateObject private var room = RoomModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RoomView(camera: room.camera).environmentObject(room)
                .onChange(of: phase) { _, value in
                    if value == .background { room.endCall() }
                    if value == .active { room.refreshConnection() }
                }
        }
    }
}
