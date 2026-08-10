import SwiftUI

@main
struct SpellbookApp: App {
    @StateObject private var sessionModel = SessionModel()
    @StateObject private var localStore = LocalSpellStore()
    @StateObject private var deepLinkModel = DeepLinkModel()

    var body: some Scene {
        WindowGroup("Spellbook") {
            RootView()
                .environmentObject(sessionModel)
                .environmentObject(localStore)
                .environmentObject(deepLinkModel)
                .preferredColorScheme(.light)
                .frame(minWidth: 980, minHeight: 660)
                .onOpenURL { url in
                    deepLinkModel.open(url)
                }
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
