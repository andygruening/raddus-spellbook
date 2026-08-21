import SwiftUI

enum SpellbookPage: String, CaseIterable, Identifiable {
    case workspaces
    case packs
    case rules
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaces: "Workspaces"
        case .packs: "Packs"
        case .rules: "Rules"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .workspaces: "folder"
        case .packs: "shippingbox"
        case .rules: "tray.full"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var deepLinkModel: DeepLinkModel
    @State private var selection: SpellbookPage? = .workspaces

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spellbook")
                        .font(.title2.bold())
                    Text("Raddus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                VStack(alignment: .leading, spacing: 22) {
                    sidebarSection("Spellbook", pages: [.workspaces, .packs, .rules, .settings])
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            switch selection ?? .workspaces {
            case .workspaces:
                ProjectsView()
            case .packs:
                PacksView()
            case .rules:
                LocalSpellsView()
            case .settings:
                SettingsView()
            }
        }
        .onAppear {
            if deepLinkModel.pendingPublishedSpellID != nil {
                selection = .rules
            }
        }
        .onChange(of: deepLinkModel.pendingPublishedSpellID) { spellID in
            if spellID != nil {
                selection = .rules
            }
        }
    }

    private func sidebarSection(_ title: String, pages: [SpellbookPage]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            VStack(spacing: 3) {
                ForEach(pages) { page in
                    sidebarButton(page)
                }
            }
        }
    }

    private func sidebarButton(_ page: SpellbookPage) -> some View {
        Button {
            selection = page
        } label: {
            Label(page.title, systemImage: page.icon)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == page ? Color.accentColor : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selection == page ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

}
