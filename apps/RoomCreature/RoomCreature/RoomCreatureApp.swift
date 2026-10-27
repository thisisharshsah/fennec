import SwiftUI

@main
struct RoomCreatureApp: App {
    @State private var model = AppModel()

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
                        if UserDefaults.standard.string(forKey: "openPage") == "history" {
                            model.navigator.path.append(.history(id))
                        }
                    }
                    #endif
                }
                .onChange(of: model.desiredEndpoint) { model.applyDesiredEndpoint() }
        }
        .defaultSize(width: 960, height: 720)
    }
}
