import Foundation

@MainActor
final class DeepLinkModel: ObservableObject {
    @Published var pendingPublishedSpellID: String?

    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "spellbook" else {
            return
        }

        if url.host?.lowercased() == "spell",
           let spellID = url.pathComponents.dropFirst().first,
           !spellID.isEmpty {
            pendingPublishedSpellID = spellID
            return
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let spellID = components.queryItems?.first(where: { $0.name == "spell" })?.value,
           !spellID.isEmpty {
            pendingPublishedSpellID = spellID
        }
    }
}
