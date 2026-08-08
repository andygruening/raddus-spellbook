import SwiftUI

enum SpellbookPage: String, CaseIterable, Identifiable {
    case local
    case staging
    case archived
    case published
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Installed"
        case .staging: "Staged"
        case .archived: "Archive"
        case .published: "Published"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .local: "tray.full"
        case .staging: "tray.and.arrow.down"
        case .archived: "archivebox"
        case .published: "globe"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
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

                    sidebarSection("My Library", pages: [.local, .staging, .archived])

                    sidebarSection("Other", pages: [.settings])
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer(minLength: 0)

                targetPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            switch selection ?? .local {
            case .local:
                LocalSpellsView()
            case .staging:
                StagingSpellsView()
            case .archived:
                ArchivedSpellsView()
            case .published:
                PublishedSpellsView()
            case .settings:
                SettingsView()
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

    private var targetPicker: some View {
        Menu {
            if localStore.targets.isEmpty {
                Text("No targets")
            } else {
                ForEach(localStore.targets) { target in
                    Button {
                        localStore.selectTarget(id: target.id)
                    } label: {
                        if target.id == localStore.selectedTargetID {
                            Label(target.name, systemImage: "checkmark")
                        } else {
                            Text(target.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(localStore.selectedTarget?.name ?? "No targets")
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.16), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .disabled(localStore.targets.isEmpty)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
