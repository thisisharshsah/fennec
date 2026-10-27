import SwiftUI

/// Welcome until there is a creature, then Home. The Add flow and Settings sit on top of either.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var navigator = model.navigator
        Group {
            if model.store.registry.creatures.isEmpty {
                NavigationStack { WelcomeView() }
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.store.registry.creatures.isEmpty)
        .tint(Theme.accent)
        .symbolRenderingMode(.hierarchical)
        #if os(iOS)
        .fullScreenCover(isPresented: $navigator.isAddingCreature) {
            AddCreatureFlow()
                .environment(model)
        }
        #else
        .sheet(isPresented: $navigator.isAddingCreature) {
            AddCreatureFlow()
                .environment(model)
        }
        #endif
        .sheet(isPresented: $navigator.isShowingSettings) {
            NavigationStack { SettingsView() }
                .environment(model)
                .tint(Theme.accent)
                #if os(macOS)
                .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
                #endif
        }
        .onChange(of: model.store.units.filter(\.isConnected).map(\.id)) {
            model.navigator.checkArrival(in: model.store.units)
        }
        #if os(macOS)
        .frame(minWidth: Theme.minWindowSize.width, minHeight: Theme.minWindowSize.height)
        #endif
    }
}
