import SwiftUI

@main
struct RoomCreatureApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    model.start()
                    #if DEBUG
                    // `-openCreature desk` opens a creature's page once it is known (for screenshots).
                    if let id = UserDefaults.standard.string(forKey: "openCreature") {
                        for _ in 0..<40 where model.store.unitsByID[id] == nil {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        model.navigator.open(id)
                        switch UserDefaults.standard.string(forKey: "openPage") {
                        case "history": model.navigator.path.append(.history(id))
                        case "conversation": model.navigator.path.append(.conversation(id))
                        default: break
                        }
                    }
                    // `-openMessages 1` opens the list of conversations.
                    if UserDefaults.standard.bool(forKey: "openMessages") {
                        model.navigator.openMessages()
                    }
                    // `-openSettings 1` shows Settings.
                    if UserDefaults.standard.bool(forKey: "openSettings") {
                        model.navigator.isShowingSettings = true
                    }
                    #endif
                }
                .onChange(of: model.desiredEndpoint) { model.applyDesiredEndpoint() }
                .onChange(of: scenePhase) { old, new in
                    if new == .background { model.backgroundedAt = .now }
                    if new == .active && old != .active { model.resume() }
                }
        }
        .defaultSize(width: 960, height: 720)
    }
}
