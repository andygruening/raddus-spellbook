import SwiftUI

enum SpellbookPage: String, CaseIterable, Identifiable {
    case local
    case projects
    case staging
    case published
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Instructions"
        case .projects: "Projects"
        case .staging: "Suggestions"
        case .published: "Published"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .local: "tray.full"
        case .projects: "folder"
        case .staging: "tray.and.arrow.down"
        case .published: "globe"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var deepLinkModel: DeepLinkModel
    @State private var selection: SpellbookPage? = .local

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
                    sidebarSection("Explore", pages: [.published])

                    sidebarSection("My Library", pages: [.projects, .local, .staging])

                    sidebarSection("Other", pages: [.settings])
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            switch selection ?? .local {
            case .local:
                LocalSpellsView()
            case .projects:
                ProjectsView()
            case .staging:
                StagingSpellsView()
            case .published:
                PublishedSpellsView()
            case .settings:
                SettingsView()
            }
        }
        .onAppear {
            if deepLinkModel.pendingPublishedSpellID != nil {
                selection = .published
            }
        }
        .onChange(of: deepLinkModel.pendingPublishedSpellID) { spellID in
            if spellID != nil {
                selection = .published
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
