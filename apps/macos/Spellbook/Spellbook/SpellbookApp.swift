import SwiftUI

@main
struct SpellbookApp: App {
    @StateObject private var sessionModel = SessionModel()
    @StateObject private var localStore = LocalSpellStore()

    var body: some Scene {
        WindowGroup("Spellbook") {
            RootView()
                .environmentObject(sessionModel)
                .environmentObject(localStore)
                .preferredColorScheme(.light)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.titleBar)
    }
}

struct RootView: View {
    @EnvironmentObject private var sessionModel: SessionModel

    var body: some View {
        if sessionModel.session == nil {
            AuthFlowView()
        } else {
            MainView()
        }
    }
}
