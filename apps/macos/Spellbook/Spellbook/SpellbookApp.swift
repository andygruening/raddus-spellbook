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
    @EnvironmentObject private var localStore: LocalSpellStore

    var body: some View {
        if sessionModel.session == nil {
            AuthFlowView()
        } else if localStore.selectedTarget == nil {
            TargetSelectionView()
        } else {
            MainView()
        }
    }
}

private struct TargetSelectionView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @State private var isShowingAddTargetForm = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Text("Choose a Target")
                        .font(.system(size: 38, weight: .semibold))

                    Text("Select the AGENTS.md, AGENT.md, or CLAUDE.md target Spellbook should manage first.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)

                    Text("You can add more targets in Settings later.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if localStore.targets.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(Color.accentColor)

                        Text("No targets selected yet.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 520)
                    .frame(minHeight: 150)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                } else {
                    VStack(spacing: 8) {
                        ForEach(localStore.targets) { target in
                            Button {
                                localStore.selectTarget(id: target.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(Color.accentColor)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(target.name)
                                            .font(.callout.weight(.semibold))
                                        Text(target.displayPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 620)
                }

                Button {
                    isShowingAddTargetForm = true
                } label: {
                    Label(localStore.targets.isEmpty ? "Choose Target" : "Add Another Target", systemImage: "folder")
                        .frame(width: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(48)
        }
        .sheet(isPresented: $isShowingAddTargetForm) {
            TargetFormView(mode: .add) { directoryURL, instructionFileName, name in
                try localStore.addTarget(directoryURL: directoryURL, instructionFileName: instructionFileName, name: name)
            }
        }
    }
}
