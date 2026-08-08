import AppKit
import Foundation

struct SpellbookTarget: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var directoryPath: String
    var instructionFileName: String
    var directoryBookmarkData: Data

    var displayPath: String {
        "\(directoryPath)/\(instructionFileName)"
    }

    func resolveDirectoryURL() throws -> URL {
        var stale = false
        return try URL(
            resolvingBookmarkData: directoryBookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    func instructionURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: instructionFileName)
    }

    func spellsURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: "spells.json")
    }

    func stagingURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: "spells-staging.json")
    }

    func archiveURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: "spells-archive.json")
    }

    func spellsDirectoryURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: "spells", directoryHint: .isDirectory)
    }
}

@MainActor
final class LocalSpellStore: ObservableObject {
    @Published private(set) var targets: [SpellbookTarget] = []
    @Published private(set) var selectedTargetID: String?
    @Published private(set) var spells: [Spell] = []
    @Published private(set) var stagingSpells: [Spell] = []
    @Published private(set) var archivedSpells: [Spell] = []
    @Published var statusMessage: String?
    @Published var lastError: String?

    private let targetsKey = "spellbook.targets"
    private let selectedTargetIDKey = "spellbook.selectedTargetID"
    private let legacyBookmarkKey = "spellbook.selectedTargetBookmark"
    private let ownerEmailsByUIDKey = "spellbook.ownerEmailsByUID"
    private var scopedURL: URL?

    init() {
        restoreTargets()
    }

    var selectedTarget: SpellbookTarget? {
        guard let selectedTargetID else {
            return nil
        }

        return targets.first { $0.id == selectedTargetID }
    }

    var selectedURL: URL? {
        guard let selectedTarget, let directoryURL = resolveDirectoryURL(for: selectedTarget) else {
            return nil
        }

        return selectedTarget.instructionURL(in: directoryURL)
    }

    var selectedDisplayPath: String {
        selectedTarget?.displayPath ?? "No target selected"
    }

    var spellsURL: URL? {
        guard let selectedTarget, let directoryURL = resolveDirectoryURL(for: selectedTarget) else {
            return nil
        }

        return selectedTarget.spellsURL(in: directoryURL)
    }

    var stagingSpellsURL: URL? {
        guard let selectedTarget, let directoryURL = resolveDirectoryURL(for: selectedTarget) else {
            return nil
        }

        return selectedTarget.stagingURL(in: directoryURL)
    }

    var archiveSpellsURL: URL? {
        guard let selectedTarget, let directoryURL = resolveDirectoryURL(for: selectedTarget) else {
            return nil
        }

        return selectedTarget.archiveURL(in: directoryURL)
    }

    func selectTarget(id: String) {
        guard targets.contains(where: { $0.id == id }) else {
            return
        }

        selectedTargetID = id
        persistSelection()

        do {
            try refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addTarget(directoryURL: URL, instructionFileName: String, name: String) throws {
        guard InstructionManager.supportedFiles.contains(instructionFileName) else {
            throw SpellbookError.message("Choose AGENTS.md, AGENT.md, or CLAUDE.md.")
        }

        let bookmarkData = try directoryURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let directoryPath = directoryURL.path(percentEncoded: false)
        let fallbackName = directoryURL.lastPathComponent.isEmpty ? directoryPath : directoryURL.lastPathComponent
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var incoming = SpellbookTarget(
            id: "target-\(UUID().uuidString)",
            name: targetName,
            directoryPath: directoryPath,
            instructionFileName: instructionFileName,
            directoryBookmarkData: bookmarkData
        )

        if let existingIndex = targets.firstIndex(where: { $0.directoryPath == directoryPath }) {
            incoming.id = targets[existingIndex].id
            targets[existingIndex] = incoming
        } else {
            targets.append(incoming)
        }

        selectedTargetID = incoming.id
        persistTargets()
        persistSelection()
        startAccessing(directoryURL)
        try refresh()
    }

    func updateTarget(_ target: SpellbookTarget, directoryURL: URL, instructionFileName: String, name: String) throws {
        guard InstructionManager.supportedFiles.contains(instructionFileName) else {
            throw SpellbookError.message("Choose AGENTS.md, AGENT.md, or CLAUDE.md.")
        }

        guard let index = targets.firstIndex(where: { $0.id == target.id }) else {
            throw SpellbookError.message("That target could not be found.")
        }

        let directoryPath = directoryURL.path(percentEncoded: false)
        if targets.contains(where: { $0.id != target.id && $0.directoryPath == directoryPath }) {
            throw SpellbookError.message("A target for that directory already exists.")
        }

        let bookmarkData = try directoryURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let fallbackName = directoryURL.lastPathComponent.isEmpty ? directoryPath : directoryURL.lastPathComponent
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : name.trimmingCharacters(in: .whitespacesAndNewlines)

        targets[index] = SpellbookTarget(
            id: target.id,
            name: targetName,
            directoryPath: directoryPath,
            instructionFileName: instructionFileName,
            directoryBookmarkData: bookmarkData
        )

        persistTargets()
        startAccessing(directoryURL)

        if selectedTargetID == target.id {
            try refresh()
        }
    }

    func removeTarget(_ target: SpellbookTarget) {
        targets.removeAll { $0.id == target.id }

        if selectedTargetID == target.id {
            selectedTargetID = targets.first?.id
        }

        persistTargets()
        persistSelection()

        do {
            try refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            spells = []
            stagingSpells = []
            archivedSpells = []
            statusMessage = targets.isEmpty ? "Add a target in Settings." : "Choose a target from the sidebar."
            return
        }

        let approvedExists = FileManager.default.fileExists(atPath: spellsURL.path(percentEncoded: false))
        let stagingExists = FileManager.default.fileExists(atPath: stagingSpellsURL.path(percentEncoded: false))
        let archiveExists = FileManager.default.fileExists(atPath: archiveSpellsURL.path(percentEncoded: false))
        let approvedRegistry = try loadRegistryIfExists(at: spellsURL)
        let stagingRegistry = try loadRegistryIfExists(at: stagingSpellsURL)
        let archiveRegistry = try loadRegistryIfExists(at: archiveSpellsURL)
        spells = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        stagingSpells = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        archivedSpells = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)

        if !approvedExists && !stagingExists && !archiveExists {
            statusMessage = "No spell registries found yet."
        } else {
            statusMessage = "Loaded \(approvedRegistry.spells.count) approved, \(stagingRegistry.spells.count) staged, and \(archiveRegistry.spells.count) archived spell\(archiveRegistry.spells.count == 1 ? "" : "s")."
        }
    }

    func upsertLocal(_ spell: Spell) throws {
        guard let spellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        var registry = try loadOrCreateRegistry(at: spellsURL)
        let hydratedSpells = hydrate(registry.spells, registryURL: spellsURL)
        var incoming = try preparedSpell(spell, registry: registry, registryURL: spellsURL)

        if let index = hydratedSpells.firstIndex(where: { $0.matchesForInstall(incoming) }) {
            let existing = registry.spells[index]
            incoming.file = existing.file
            incoming.uid = incoming.uid ?? existing.uid
            incoming.ownerEmail = incoming.ownerEmail ?? hydratedSpells[index].ownerEmail
            incoming.content = incoming.content ?? hydratedSpells[index].content
            registry.spells[index] = incoming
        } else {
            registry.spells.insert(incoming, at: 0)
        }

        rememberOwner(for: incoming)
        try writeMarkdown(for: incoming, registryURL: spellsURL)
        try save(registry, to: spellsURL)
        spells = hydrate(registry.spells, registryURL: spellsURL)
        statusMessage = "Updated spells.json."
    }

    func updateLocal(_ spell: Spell) throws {
        guard let spellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        var registry = try loadOrCreateRegistry(at: spellsURL)
        let hydratedSpells = hydrate(registry.spells, registryURL: spellsURL)
        guard let index = hydratedSpells.firstIndex(where: { $0.id == spell.id }) else {
            throw SpellbookError.message("That local spell could not be found.")
        }

        var updated = spell
        updated.file = registry.spells[index].file
        updated.uid = updated.uid ?? registry.spells[index].uid
        updated.ownerEmail = updated.ownerEmail ?? hydratedSpells[index].ownerEmail
        registry.spells[index] = updated

        rememberOwner(for: updated)
        try writeMarkdown(for: updated, registryURL: spellsURL)
        try save(registry, to: spellsURL)
        spells = hydrate(registry.spells, registryURL: spellsURL)
        statusMessage = "Updated \(updated.name)."
    }

    func updateAfterPublish(localIdentifier: String, remoteSpell: Spell, signedInEmail: String) throws {
        guard let spellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        var registry = try loadOrCreateRegistry(at: spellsURL)
        let hydratedSpells = hydrate(registry.spells, registryURL: spellsURL)
        guard let index = hydratedSpells.firstIndex(where: { $0.id == localIdentifier }) else {
            throw SpellbookError.message("That local spell could not be found.")
        }

        var updated = registry.spells[index]
        updated.uid = remoteSpell.uid
        updated.name = remoteSpell.name
        updated.description = remoteSpell.description
        updated.tags = remoteSpell.tags
        updated.content = hydratedSpells[index].content ?? remoteSpell.content
        updated.ownerEmail = signedInEmail
        updated.publishedAt = remoteSpell.publishedAt
        registry.spells[index] = updated

        rememberOwner(for: updated)
        try writeMarkdown(for: updated, registryURL: spellsURL)
        try save(registry, to: spellsURL)
        spells = hydrate(registry.spells, registryURL: spellsURL)
        statusMessage = "Published \(updated.name)."
    }

    func approveStaged(_ spell: Spell) throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        var approvedRegistry = try loadOrCreateRegistry(at: spellsURL)
        var stagingRegistry = try loadOrCreateRegistry(at: stagingSpellsURL)
        let archiveRegistry = try loadOrCreateRegistry(at: archiveSpellsURL)
        let hydratedStaging = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        guard let stagingIndex = hydratedStaging.firstIndex(where: { $0.id == spell.id }) else {
            throw SpellbookError.message("That staged spell could not be found.")
        }

        let stagedIndexEntry = stagingRegistry.spells.remove(at: stagingIndex)
        var incoming = hydratedStaging[stagingIndex]
        incoming.uid = incoming.uid ?? stagedIndexEntry.uid
        incoming.file = stagedIndexEntry.file
        let stagedFile = incoming.file

        let approvedHydrated = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        if let approvedIndex = approvedHydrated.firstIndex(where: { $0.matchesForInstall(incoming) }) {
            let existing = approvedRegistry.spells[approvedIndex]
            incoming.file = existing.file
            incoming.uid = incoming.uid ?? existing.uid
            incoming.ownerEmail = incoming.ownerEmail ?? approvedHydrated[approvedIndex].ownerEmail
            incoming.content = incoming.content ?? approvedHydrated[approvedIndex].content
            approvedRegistry.spells[approvedIndex] = incoming
        } else {
            incoming = try preparedSpell(incoming, registry: approvedRegistry, registryURL: spellsURL)
            approvedRegistry.spells.insert(incoming, at: 0)
        }

        rememberOwner(for: incoming)
        try writeMarkdown(for: incoming, registryURL: spellsURL)
        try save(approvedRegistry, to: spellsURL)
        try save(stagingRegistry, to: stagingSpellsURL)
        try removeMarkdownIfUnreferenced(file: stagedFile, registryURL: spellsURL, registries: [approvedRegistry, stagingRegistry, archiveRegistry])

        spells = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        stagingSpells = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        archivedSpells = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)
        statusMessage = "Approved \(incoming.name)."
    }

    func removeStaged(_ spell: Spell) throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        let approvedRegistry = try loadOrCreateRegistry(at: spellsURL)
        var stagingRegistry = try loadOrCreateRegistry(at: stagingSpellsURL)
        var archiveRegistry = try loadOrCreateRegistry(at: archiveSpellsURL)
        let hydratedStaging = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        guard let stagingIndex = hydratedStaging.firstIndex(where: { $0.id == spell.id }) else {
            throw SpellbookError.message("That staged spell could not be found.")
        }

        let stagedIndexEntry = stagingRegistry.spells.remove(at: stagingIndex)
        var archived = hydratedStaging[stagingIndex]
        archived.uid = archived.uid ?? stagedIndexEntry.uid
        archived.file = stagedIndexEntry.file
        let stagedFile = archived.file
        archived = try upsertArchived(archived, archiveRegistry: &archiveRegistry, archiveURL: archiveSpellsURL)

        rememberOwner(for: archived)
        try writeMarkdown(for: archived, registryURL: archiveSpellsURL)
        try save(stagingRegistry, to: stagingSpellsURL)
        try save(archiveRegistry, to: archiveSpellsURL)
        try removeMarkdownIfUnreferenced(file: stagedFile, registryURL: spellsURL, registries: [approvedRegistry, stagingRegistry, archiveRegistry])

        spells = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        stagingSpells = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        archivedSpells = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)
        statusMessage = "Archived staged spell \(archived.name)."
    }

    func removeLocal(_ spell: Spell) throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        var approvedRegistry = try loadOrCreateRegistry(at: spellsURL)
        let stagingRegistry = try loadOrCreateRegistry(at: stagingSpellsURL)
        var archiveRegistry = try loadOrCreateRegistry(at: archiveSpellsURL)
        let hydratedSpells = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        if let index = hydratedSpells.firstIndex(where: { $0.id == spell.id }) {
            let approvedIndexEntry = approvedRegistry.spells.remove(at: index)
            var archived = hydratedSpells[index]
            archived.uid = archived.uid ?? approvedIndexEntry.uid
            archived.file = approvedIndexEntry.file
            let approvedFile = archived.file
            archived = try upsertArchived(archived, archiveRegistry: &archiveRegistry, archiveURL: archiveSpellsURL)

            rememberOwner(for: archived)
            try writeMarkdown(for: archived, registryURL: archiveSpellsURL)
            try removeMarkdownIfUnreferenced(file: approvedFile, registryURL: spellsURL, registries: [approvedRegistry, stagingRegistry, archiveRegistry])
            statusMessage = "Archived \(archived.name)."
        }
        try save(approvedRegistry, to: spellsURL)
        try save(archiveRegistry, to: archiveSpellsURL)
        spells = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        stagingSpells = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        archivedSpells = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)
    }

    func restoreArchived(_ spell: Spell) throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        var approvedRegistry = try loadOrCreateRegistry(at: spellsURL)
        let stagingRegistry = try loadOrCreateRegistry(at: stagingSpellsURL)
        var archiveRegistry = try loadOrCreateRegistry(at: archiveSpellsURL)
        let hydratedArchive = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)
        guard let archiveIndex = hydratedArchive.firstIndex(where: { $0.id == spell.id }) else {
            throw SpellbookError.message("That archived spell could not be found.")
        }

        let archivedIndexEntry = archiveRegistry.spells.remove(at: archiveIndex)
        var restored = hydratedArchive[archiveIndex]
        restored.uid = restored.uid ?? archivedIndexEntry.uid
        restored.file = archivedIndexEntry.file
        let archivedFile = restored.file

        let approvedHydrated = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        if let approvedIndex = approvedHydrated.firstIndex(where: { $0.matchesForInstall(restored) }) {
            let existing = approvedRegistry.spells[approvedIndex]
            restored.file = existing.file
            restored.uid = restored.uid ?? existing.uid
            restored.ownerEmail = restored.ownerEmail ?? approvedHydrated[approvedIndex].ownerEmail
            restored.content = restored.content ?? approvedHydrated[approvedIndex].content
            approvedRegistry.spells[approvedIndex] = restored
        } else {
            restored = try preparedSpell(restored, registry: approvedRegistry, registryURL: spellsURL)
            approvedRegistry.spells.insert(restored, at: 0)
        }

        rememberOwner(for: restored)
        try writeMarkdown(for: restored, registryURL: spellsURL)
        try save(approvedRegistry, to: spellsURL)
        try save(archiveRegistry, to: archiveSpellsURL)
        try removeMarkdownIfUnreferenced(file: archivedFile, registryURL: spellsURL, registries: [approvedRegistry, stagingRegistry, archiveRegistry])

        spells = hydrate(approvedRegistry.spells, registryURL: spellsURL)
        stagingSpells = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        archivedSpells = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)
        statusMessage = "Restored \(restored.name)."
    }

    func createEmptyRegistryIfMissing() throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            throw SpellbookError.message("Choose a local Spellbook target in Settings first.")
        }

        if !FileManager.default.fileExists(atPath: spellsURL.path(percentEncoded: false)) {
            try save(.empty, to: spellsURL)
        }

        if !FileManager.default.fileExists(atPath: stagingSpellsURL.path(percentEncoded: false)) {
            try save(.empty, to: stagingSpellsURL)
        }

        if !FileManager.default.fileExists(atPath: archiveSpellsURL.path(percentEncoded: false)) {
            try save(.empty, to: archiveSpellsURL)
        }

        try FileManager.default.createDirectory(
            at: spellsURL.deletingLastPathComponent().appending(path: "spells", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try refresh()
    }

    private func loadRegistryIfExists(at url: URL) throws -> SpellRegistry {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .empty
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.spellbook.decode(SpellRegistry.self, from: data)
    }

    private func loadOrCreateRegistry(at url: URL) throws -> SpellRegistry {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .empty
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.spellbook.decode(SpellRegistry.self, from: data)
    }

    private func save(_ registry: SpellRegistry, to url: URL) throws {
        let data = try JSONEncoder.spellbook.encode(registry)
        try data.write(to: url, options: [.atomic])
    }

    private func hydrate(_ spells: [Spell], registryURL: URL) -> [Spell] {
        spells.map { spell in
            var hydrated = spell
            if hydrated.ownerEmail == nil, let uid = hydrated.uid {
                hydrated.ownerEmail = ownerEmail(for: uid)
            }
            if let markdownURL = try? markdownURL(for: spell, registryURL: registryURL),
               FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)),
               let content = try? String(contentsOf: markdownURL, encoding: .utf8) {
                hydrated.content = content
            }
            return hydrated
        }
    }

    private func preparedSpell(_ spell: Spell, registry: SpellRegistry, registryURL: URL) throws -> Spell {
        var incoming = spell
        let existingFiles = Set(registry.spells.map(\.file))
        if incoming.file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (try? markdownURL(for: incoming, registryURL: registryURL)) == nil
            || existingFiles.contains(incoming.file) {
            incoming.file = uniqueFilePath(for: incoming.name, existingSpells: registry.spells)
        }
        return incoming
    }

    private func upsertArchived(_ spell: Spell, archiveRegistry: inout SpellRegistry, archiveURL: URL) throws -> Spell {
        var incoming = spell
        let hydratedArchive = hydrate(archiveRegistry.spells, registryURL: archiveURL)
        if let index = hydratedArchive.firstIndex(where: { $0.matchesForInstall(incoming) }) {
            let existing = archiveRegistry.spells[index]
            incoming.file = existing.file
            incoming.uid = incoming.uid ?? existing.uid
            incoming.ownerEmail = incoming.ownerEmail ?? hydratedArchive[index].ownerEmail
            incoming.content = incoming.content ?? hydratedArchive[index].content
            archiveRegistry.spells[index] = incoming
        } else {
            incoming = try preparedSpell(incoming, registry: archiveRegistry, registryURL: archiveURL)
            archiveRegistry.spells.insert(incoming, at: 0)
        }

        return incoming
    }

    private func uniqueFilePath(for name: String, existingSpells: [Spell]) -> String {
        let base = Spell.slug(for: name)
        let existingPaths = Set(existingSpells.map(\.file))
        var candidate = "spells/\(base).md"
        var suffix = 2

        while existingPaths.contains(candidate) {
            candidate = "spells/\(base)-\(suffix).md"
            suffix += 1
        }

        return candidate
    }

    private func writeMarkdown(for spell: Spell, registryURL: URL) throws {
        let markdownURL = try markdownURL(for: spell, registryURL: registryURL)
        try FileManager.default.createDirectory(
            at: markdownURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let markdown = spell.content ?? "# \(spell.name)\n\n\(spell.description)\n"
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    }

    private func removeMarkdownIfUnreferenced(file: String, registryURL: URL, registries: [SpellRegistry]) throws {
        let trimmedFile = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFile.isEmpty else {
            return
        }

        let isReferenced = registries.contains { registry in
            registry.spells.contains { $0.file == trimmedFile }
        }
        guard !isReferenced else {
            return
        }

        let placeholder = Spell(name: "Removed spell", description: "", file: trimmedFile)
        guard let markdownURL = try? markdownURL(for: placeholder, registryURL: registryURL),
              FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)) else {
            return
        }

        try FileManager.default.removeItem(at: markdownURL)
    }

    private func markdownURL(for spell: Spell, registryURL: URL) throws -> URL {
        let trimmedFile = spell.file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFile.isEmpty, !trimmedFile.hasPrefix("/") else {
            throw SpellbookError.message("spells.json contains an invalid spell file path.")
        }

        let parts = trimmedFile.split(separator: "/").map(String.init)
        guard parts.count == 2,
              parts[0] == "spells",
              parts[1].hasSuffix(".md"),
              !parts[1].contains("..") else {
            throw SpellbookError.message("Spell files must live under ./spells and end in .md.")
        }

        return registryURL
            .deletingLastPathComponent()
            .appending(path: "spells", directoryHint: .isDirectory)
            .appending(path: parts[1])
    }

    private func rememberOwner(for spell: Spell) {
        guard let uid = spell.uid, let ownerEmail = spell.ownerEmail else {
            return
        }

        var cache = ownerEmailsByUID()
        cache[uid] = ownerEmail
        UserDefaults.standard.set(cache, forKey: ownerEmailsByUIDKey)
    }

    private func ownerEmail(for uid: String) -> String? {
        ownerEmailsByUID()[uid]
    }

    private func ownerEmailsByUID() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: ownerEmailsByUIDKey) as? [String: String] ?? [:]
    }

    private func restoreTargets() {
        if let data = UserDefaults.standard.data(forKey: targetsKey),
           let decoded = try? JSONDecoder.spellbook.decode([SpellbookTarget].self, from: data) {
            targets = decoded
            selectedTargetID = UserDefaults.standard.string(forKey: selectedTargetIDKey) ?? decoded.first?.id
            do {
                try refresh()
            } catch {
                lastError = "Choose the Spellbook target again."
            }
            return
        }

        restoreLegacyTarget()
    }

    private func restoreLegacyTarget() {
        guard let data = UserDefaults.standard.data(forKey: legacyBookmarkKey) else {
            return
        }

        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let directoryURL = url.spellbookIsDirectory ? url : url.deletingLastPathComponent()
            let instructionFileName = url.spellbookIsDirectory ? InstructionManager.supportedFiles[0] : url.lastPathComponent

            if InstructionManager.supportedFiles.contains(instructionFileName) {
                try addTarget(directoryURL: directoryURL, instructionFileName: instructionFileName, name: directoryURL.lastPathComponent)
                UserDefaults.standard.removeObject(forKey: legacyBookmarkKey)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: legacyBookmarkKey)
            lastError = "Choose the Spellbook target again."
        }
    }

    private func resolveDirectoryURL(for target: SpellbookTarget) -> URL? {
        do {
            let url = try target.resolveDirectoryURL()
            startAccessing(url)
            return url
        } catch {
            return nil
        }
    }

    func directoryURL(for target: SpellbookTarget) -> URL? {
        resolveDirectoryURL(for: target)
    }

    private func persistTargets() {
        guard let data = try? JSONEncoder.spellbook.encode(targets) else {
            return
        }

        UserDefaults.standard.set(data, forKey: targetsKey)
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedTargetID, forKey: selectedTargetIDKey)
    }

    private func startAccessing(_ url: URL) {
        if scopedURL != url {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = url
            _ = url.startAccessingSecurityScopedResource()
        }
    }
}
