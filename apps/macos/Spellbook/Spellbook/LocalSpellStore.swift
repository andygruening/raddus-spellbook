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
        AgentContextLayout.registryURL(in: directoryURL)
    }

    func stagingURL(in directoryURL: URL) -> URL {
        SpellbookUserStoreLayout.stagingURL
    }

    func archiveURL(in directoryURL: URL) -> URL {
        SpellbookUserStoreLayout.archiveURL
    }

    func spellsDirectoryURL(in directoryURL: URL) -> URL {
        SpellbookUserStoreLayout.spellsDirectoryURL
    }
}

@MainActor
final class LocalSpellStore: ObservableObject {
    @Published private(set) var targets: [SpellbookTarget] = []
    @Published private(set) var spells: [Spell] = []
    @Published private(set) var projectSpellsByTargetID: [String: [Spell]] = [:]
    @Published private(set) var stagingSpells: [Spell] = []
    @Published private(set) var archivedSpells: [Spell] = []
    @Published var statusMessage: String?
    @Published var lastError: String?

    private let targetsKey = "spellbook.targets"
    private let legacyBookmarkKey = "spellbook.selectedTargetBookmark"
    private let ownerEmailsByUIDKey = "spellbook.ownerEmailsByUID"
    private var scopedURL: URL?

    init() {
        restoreTargets()
    }

    var spellsURL: URL? {
        SpellbookUserStoreLayout.libraryURL
    }

    var stagingSpellsURL: URL? {
        SpellbookUserStoreLayout.stagingURL
    }

    var archiveSpellsURL: URL? {
        SpellbookUserStoreLayout.archiveURL
    }

    func projectSpells(for target: SpellbookTarget) -> [Spell] {
        projectSpellsByTargetID[target.id] ?? []
    }

    func target(_ target: SpellbookTarget, contains spell: Spell) -> Bool {
        projectSpells(for: target).contains { projectSpell in
            projectSpell.hasSameIdentity(as: spell)
        }
    }

    func projectTargets(containing spell: Spell) -> [SpellbookTarget] {
        targets.filter { target in
            self.target(target, contains: spell)
        }
    }

    func isConnectedToAnyProject(_ spell: Spell) -> Bool {
        !projectTargets(containing: spell).isEmpty
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

        startAccessing(directoryURL)
        let preview = try InstructionManager.preview(
            selectedURL: incoming.instructionURL(in: directoryURL),
            preferredFileName: incoming.instructionFileName
        )
        try InstructionManager.apply(preview)

        if let existingIndex = targets.firstIndex(where: { $0.directoryPath == directoryPath }) {
            incoming.id = targets[existingIndex].id
            targets[existingIndex] = incoming
        } else {
            targets.append(incoming)
        }

        persistTargets()
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

        try refresh()
    }

    func removeTarget(_ target: SpellbookTarget) throws {
        guard let index = targets.firstIndex(where: { $0.id == target.id }) else {
            throw SpellbookError.message("That target could not be found.")
        }

        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the target directory again before removing it.")
        }

        try InstructionManager.removeManagedBlock(from: target.instructionURL(in: directoryURL))
        targets.remove(at: index)
        stopAccessingRemovedTarget(directoryURL)

        persistTargets()

        do {
            try refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() throws {
        try migrateLibraryFromProjectRegistriesIfNeeded()

        let librarySpellsURL = SpellbookUserStoreLayout.libraryURL
        let stagingSpellsURL = SpellbookUserStoreLayout.stagingURL
        let archiveSpellsURL = SpellbookUserStoreLayout.archiveURL

        let approvedExists = FileManager.default.fileExists(atPath: librarySpellsURL.path(percentEncoded: false))
        let stagingExists = FileManager.default.fileExists(atPath: stagingSpellsURL.path(percentEncoded: false))
        let archiveExists = FileManager.default.fileExists(atPath: archiveSpellsURL.path(percentEncoded: false))
        let approvedRegistry = try loadRegistryIfExists(at: librarySpellsURL)
        let stagingRegistry = try loadRegistryIfExists(at: stagingSpellsURL)
        let archiveRegistry = try loadRegistryIfExists(at: archiveSpellsURL)
        spells = hydrate(approvedRegistry.spells, registryURL: librarySpellsURL)
        stagingSpells = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        archivedSpells = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)
        projectSpellsByTargetID = try loadProjectSpellsByTargetID()

        if !approvedExists && !stagingExists && !archiveExists {
            statusMessage = "No spell registries found yet."
        } else {
            statusMessage = "Loaded \(approvedRegistry.spells.count) installed, \(stagingRegistry.spells.count) suggested, and \(archiveRegistry.spells.count) archived spell\(archiveRegistry.spells.count == 1 ? "" : "s")."
        }
    }

    func upsertLocal(_ spell: Spell) throws {
        guard let spellsURL else {
            throw SpellbookError.message("The local Spellbook library could not be resolved.")
        }

        var registry = try loadOrCreateRegistry(at: spellsURL)
        let hydratedSpells = hydrate(registry.spells, registryURL: spellsURL)
        var incoming = try preparedSpell(spell, registry: registry, registryURL: spellsURL)

        if let index = hydratedSpells.firstIndex(where: { $0.matchesForInstall(incoming) }) {
            let existing = registry.spells[index]
            incoming.file = existing.file
            incoming.uid = incoming.uid ?? existing.uid
            incoming.localID = incoming.localID ?? existing.localID
            incoming.version = max(incoming.version, existing.version)
            incoming.ownerEmail = incoming.ownerEmail ?? hydratedSpells[index].ownerEmail
            incoming.content = incoming.content ?? hydratedSpells[index].content
            if incoming.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                incoming.trigger = hydratedSpells[index].trigger
            }
            registry.spells[index] = incoming
        } else {
            registry.spells.insert(incoming, at: 0)
        }

        rememberOwner(for: incoming)
        try writeMarkdown(for: incoming, registryURL: spellsURL)
        try save(registry, to: spellsURL)
        spells = hydrate(registry.spells, registryURL: spellsURL)
        statusMessage = "Updated library.json."
    }

    func updateLocal(_ spell: Spell) throws {
        guard let spellsURL else {
            throw SpellbookError.message("The local Spellbook library could not be resolved.")
        }

        var registry = try loadOrCreateRegistry(at: spellsURL)
        let hydratedSpells = hydrate(registry.spells, registryURL: spellsURL)
        guard let index = hydratedSpells.firstIndex(where: { $0.id == spell.id }) else {
            throw SpellbookError.message("That local spell could not be found.")
        }

        var updated = spell
        updated.file = registry.spells[index].file
        updated.uid = updated.uid ?? registry.spells[index].uid
        updated.localID = updated.localID ?? registry.spells[index].localID
        updated.version = updated.normalizedVersion
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
            throw SpellbookError.message("The local Spellbook library could not be resolved.")
        }

        var registry = try loadOrCreateRegistry(at: spellsURL)
        let hydratedSpells = hydrate(registry.spells, registryURL: spellsURL)
        guard let index = hydratedSpells.firstIndex(where: { $0.id == localIdentifier }) else {
            throw SpellbookError.message("That local spell could not be found.")
        }

        var updated = registry.spells[index]
        updated.uid = remoteSpell.uid
        updated.localID = registry.spells[index].localID
        updated.name = remoteSpell.name
        updated.description = remoteSpell.description
        updated.trigger = remoteSpell.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? hydratedSpells[index].trigger
            : remoteSpell.trigger
        updated.tags = remoteSpell.tags
        updated.version = remoteSpell.version
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

    @discardableResult
    func markUnpublished(uid: String, replacement: Spell? = nil) throws -> Spell? {
        guard let spellsURL else {
            throw SpellbookError.message("The local Spellbook library could not be resolved.")
        }

        var registry = try loadOrCreateRegistry(at: spellsURL)
        let hydratedSpells = hydrate(registry.spells, registryURL: spellsURL)
        guard let index = hydratedSpells.indices.first(where: { hydratedSpells[$0].uid == uid || registry.spells[$0].uid == uid }) else {
            return nil
        }

        var updated = registry.spells[index]
        let hydrated = hydratedSpells[index]
        if let replacement {
            updated.name = replacement.name
            updated.description = replacement.description
            updated.trigger = replacement.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? hydrated.trigger
                : replacement.trigger
            updated.tags = replacement.tags
            updated.content = replacement.content ?? hydrated.content
            updated.version = replacement.normalizedVersion
        } else {
            updated.content = hydrated.content
            updated.version = hydrated.normalizedVersion
        }

        updated.localID = updated.localID ?? hydrated.localID ?? replacement?.localID ?? "local-\(UUID().uuidString)"
        updated.uid = nil
        updated.ownerEmail = nil
        updated.publishedAt = nil
        updated.starCount = 0
        updated.starredByMe = false
        registry.spells[index] = updated

        try writeMarkdown(for: updated, registryURL: spellsURL)
        try save(registry, to: spellsURL)
        spells = hydrate(registry.spells, registryURL: spellsURL)
        statusMessage = "Marked \(updated.name) as local only."
        return spells.first { $0.id == updated.id } ?? updated
    }

    func approveStaged(_ spell: Spell) throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            throw SpellbookError.message("The local Spellbook library could not be resolved.")
        }

        var approvedRegistry = try loadOrCreateRegistry(at: spellsURL)
        var stagingRegistry = try loadOrCreateRegistry(at: stagingSpellsURL)
        let archiveRegistry = try loadOrCreateRegistry(at: archiveSpellsURL)
        let hydratedStaging = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        guard let stagingIndex = hydratedStaging.firstIndex(where: { $0.id == spell.id }) else {
            throw SpellbookError.message("That suggested instruction could not be found.")
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
            incoming.localID = incoming.localID ?? existing.localID
            incoming.version = max(incoming.version, existing.version)
            incoming.ownerEmail = incoming.ownerEmail ?? approvedHydrated[approvedIndex].ownerEmail
            incoming.content = incoming.content ?? approvedHydrated[approvedIndex].content
            if incoming.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                incoming.trigger = approvedHydrated[approvedIndex].trigger
            }
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
        let stagingSpellsURL = SpellbookUserStoreLayout.stagingURL
        let archiveSpellsURL = SpellbookUserStoreLayout.archiveURL

        let approvedRegistry = try spellsURL.map { try loadOrCreateRegistry(at: $0) } ?? .empty
        var stagingRegistry = try loadOrCreateRegistry(at: stagingSpellsURL)
        var archiveRegistry = try loadOrCreateRegistry(at: archiveSpellsURL)
        let hydratedStaging = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        guard let stagingIndex = hydratedStaging.firstIndex(where: { $0.id == spell.id }) else {
            throw SpellbookError.message("That suggested instruction could not be found.")
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
        if let spellsURL {
            try removeMarkdownIfUnreferenced(file: stagedFile, registryURL: spellsURL, registries: [approvedRegistry, stagingRegistry, archiveRegistry])
        }

        spells = spellsURL.map { hydrate(approvedRegistry.spells, registryURL: $0) } ?? []
        stagingSpells = hydrate(stagingRegistry.spells, registryURL: stagingSpellsURL)
        archivedSpells = hydrate(archiveRegistry.spells, registryURL: archiveSpellsURL)
        statusMessage = "Archived suggestion \(archived.name)."
    }

    func removeLocal(_ spell: Spell) throws {
        guard let spellsURL, let stagingSpellsURL, let archiveSpellsURL else {
            throw SpellbookError.message("The local Spellbook library could not be resolved.")
        }

        projectSpellsByTargetID = try loadProjectSpellsByTargetID()
        let connectedTargets = projectTargets(containing: spell)
        guard connectedTargets.isEmpty else {
            let projectNames = connectedTargets.map(\.name).joined(separator: ", ")
            throw SpellbookError.message("Remove this instruction from \(projectNames) before archiving it.")
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
            throw SpellbookError.message("The local Spellbook library could not be resolved.")
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
            restored.localID = restored.localID ?? existing.localID
            restored.version = max(restored.version, existing.version)
            restored.ownerEmail = restored.ownerEmail ?? approvedHydrated[approvedIndex].ownerEmail
            restored.content = restored.content ?? approvedHydrated[approvedIndex].content
            if restored.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                restored.trigger = approvedHydrated[approvedIndex].trigger
            }
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
            throw SpellbookError.message("The local Spellbook registry could not be resolved.")
        }

        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.spellsDirectoryURL, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: spellsURL.path(percentEncoded: false)) {
            let activeRegistry = SpellRegistry(
                version: 1,
                agent: nil,
                spells: []
            )
            try save(activeRegistry, to: spellsURL)
        }

        if !FileManager.default.fileExists(atPath: stagingSpellsURL.path(percentEncoded: false)) {
            try save(.empty, to: stagingSpellsURL)
        }

        if !FileManager.default.fileExists(atPath: archiveSpellsURL.path(percentEncoded: false)) {
            try save(.empty, to: archiveSpellsURL)
        }

        try FileManager.default.createDirectory(
            at: SpellbookUserStoreLayout.spellsDirectoryURL,
            withIntermediateDirectories: true
        )
        try refresh()
    }

    func addToTarget(_ spell: Spell, target: SpellbookTarget) throws {
        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the project directory again before adding instructions.")
        }

        try ensureProjectPackage(for: target, directoryURL: directoryURL)
        let projectRegistryURL = target.spellsURL(in: directoryURL)
        var registry = try loadOrCreateRegistry(at: projectRegistryURL)
        let hydratedProjectSpells = hydrate(registry.spells, registryURL: projectRegistryURL)
        var incoming = projectReference(for: spell)

        if let index = indexOfMatchingSpell(incoming, hydratedSpells: hydratedProjectSpells, rawSpells: registry.spells) {
            let existing = registry.spells[index]
            incoming.uid = incoming.uid ?? existing.uid
            incoming.localID = incoming.localID ?? existing.localID
            incoming.version = max(incoming.version, existing.version)
            registry.spells[index] = incoming
        } else {
            registry.spells.insert(incoming, at: 0)
        }

        try save(registry, to: projectRegistryURL)
        projectSpellsByTargetID[target.id] = hydrate(registry.spells, registryURL: projectRegistryURL)
        statusMessage = "Added \(incoming.name) to \(target.name)."
    }

    func removeFromTarget(_ spell: Spell, target: SpellbookTarget) throws {
        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the project directory again before removing instructions.")
        }

        let projectRegistryURL = try writableProjectRegistryURL(for: target, directoryURL: directoryURL)
        var registry = try loadOrCreateRegistry(at: projectRegistryURL)
        let hydratedProjectSpells = hydrate(registry.spells, registryURL: projectRegistryURL)
        guard let index = indexOfMatchingSpell(spell, hydratedSpells: hydratedProjectSpells, rawSpells: registry.spells) else {
            throw SpellbookError.message("That instruction is not installed in this project.")
        }

        let removed = hydratedProjectSpells[index]
        registry.spells.remove(at: index)
        try save(registry, to: projectRegistryURL)
        projectSpellsByTargetID[target.id] = hydrate(registry.spells, registryURL: projectRegistryURL)
        statusMessage = "Removed \(removed.name) from \(target.name)."
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func loadProjectSpellsByTargetID() throws -> [String: [Spell]] {
        var projectSpells: [String: [Spell]] = [:]

        for target in targets {
            guard let directoryURL = resolveDirectoryURL(for: target) else {
                projectSpells[target.id] = []
                continue
            }

            let registryURL = readableProjectRegistryURL(for: target, directoryURL: directoryURL)
            let registry = try loadRegistryIfExists(at: registryURL)
            projectSpells[target.id] = hydrate(registry.spells, registryURL: registryURL)
        }

        return projectSpells
    }

    private func ensureProjectPackage(for target: SpellbookTarget, directoryURL: URL) throws {
        let preview = try InstructionManager.preview(
            selectedURL: target.instructionURL(in: directoryURL),
            preferredFileName: target.instructionFileName
        )
        try InstructionManager.apply(preview)
    }

    private func readableProjectRegistryURL(for target: SpellbookTarget, directoryURL: URL) -> URL {
        let primaryURL = target.spellsURL(in: directoryURL)
        if FileManager.default.fileExists(atPath: primaryURL.path(percentEncoded: false)) {
            return primaryURL
        }

        let legacyURLs = legacyProjectRegistryURLs(in: directoryURL)
        return legacyURLs.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? primaryURL
    }

    private func writableProjectRegistryURL(for target: SpellbookTarget, directoryURL: URL) throws -> URL {
        let primaryURL = target.spellsURL(in: directoryURL)
        guard !FileManager.default.fileExists(atPath: primaryURL.path(percentEncoded: false)) else {
            return primaryURL
        }

        let readableURL = readableProjectRegistryURL(for: target, directoryURL: directoryURL)
        if readableURL != primaryURL,
           FileManager.default.fileExists(atPath: readableURL.path(percentEncoded: false)) {
            let registry = try loadRegistryIfExists(at: readableURL)
            try save(registry, to: primaryURL)
        }

        return primaryURL
    }

    private func legacyProjectRegistryURLs(in directoryURL: URL) -> [URL] {
        [
            AgentContextLayout.packageURL(in: directoryURL).appending(path: AgentContextLayout.legacyRegistryFileName),
            AgentContextLayout.packageURL(in: directoryURL).appending(path: "instruction-registry.json"),
            AgentContextLayout.registryDirectoryURL(in: directoryURL).appending(path: "master.json"),
            directoryURL.appending(path: "spells.json")
        ]
    }

    private func projectReference(for spell: Spell) -> Spell {
        var reference = spell
        reference.file = ""
        reference.content = nil
        reference.ownerEmail = nil
        reference.publishedAt = nil
        reference.starCount = 0
        reference.starredByMe = false
        reference.version = reference.normalizedVersion
        return reference
    }

    private func indexOfMatchingSpell(_ spell: Spell, hydratedSpells: [Spell], rawSpells: [Spell]) -> Int? {
        hydratedSpells.indices.first { index in
            hydratedSpells[index].hasSameIdentity(as: spell)
                || rawSpells[index].hasSameIdentity(as: spell)
                || hydratedSpells[index].matchesForInstall(spell)
        }
    }

    private func migrateLibraryFromProjectRegistriesIfNeeded() throws {
        let libraryURL = SpellbookUserStoreLayout.libraryURL
        guard !FileManager.default.fileExists(atPath: libraryURL.path(percentEncoded: false)) else {
            return
        }

        var libraryRegistry = SpellRegistry.empty
        var didImport = false

        for target in targets {
            guard let directoryURL = resolveDirectoryURL(for: target) else {
                continue
            }

            let registryURL = readableProjectRegistryURL(for: target, directoryURL: directoryURL)
            guard FileManager.default.fileExists(atPath: registryURL.path(percentEncoded: false)) else {
                continue
            }

            let registry = try loadRegistryIfExists(at: registryURL)
            let hydratedSpells = hydrate(registry.spells, registryURL: registryURL)

            for spell in hydratedSpells {
                var incoming = try preparedSpell(spell, registry: libraryRegistry, registryURL: libraryURL)
                let hydratedLibrary = hydrate(libraryRegistry.spells, registryURL: libraryURL)
                if let index = indexOfMatchingSpell(incoming, hydratedSpells: hydratedLibrary, rawSpells: libraryRegistry.spells) {
                    let existing = libraryRegistry.spells[index]
                    incoming.uid = incoming.uid ?? existing.uid
                    incoming.localID = incoming.localID ?? existing.localID
                    incoming.version = max(incoming.version, existing.version)
                    incoming.content = incoming.content ?? hydratedLibrary[index].content
                    libraryRegistry.spells[index] = incoming
                } else {
                    libraryRegistry.spells.insert(incoming, at: 0)
                }

                rememberOwner(for: incoming)
                try writeMarkdown(for: incoming, registryURL: libraryURL)
                didImport = true
            }
        }

        if didImport {
            try save(libraryRegistry, to: libraryURL)
        }
    }

    private func hydrate(_ spells: [Spell], registryURL: URL) -> [Spell] {
        spells.map { spell in
            var hydrated = spell
            if hydrated.ownerEmail == nil, let uid = hydrated.uid {
                hydrated.ownerEmail = ownerEmail(for: uid)
            }
            if let content = versionedMarkdownContent(for: hydrated) {
                hydrated.content = content
                if hydrated.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hydrated.trigger = Spell.trigger(from: content) ?? ""
                }
            } else if let content = legacyMarkdownContent(for: hydrated, registryURL: registryURL) {
                hydrated.content = content
                if hydrated.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hydrated.trigger = Spell.trigger(from: content) ?? ""
                }
                try? writeMarkdown(for: hydrated, registryURL: registryURL)
            }
            return hydrated
        }
    }

    private func preparedSpell(_ spell: Spell, registry: SpellRegistry, registryURL: URL) throws -> Spell {
        var incoming = spell
        if incoming.uid == nil && incoming.localID == nil {
            incoming.localID = "local-\(UUID().uuidString)"
        }
        incoming.version = incoming.normalizedVersion

        if !incoming.file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (try? legacyMarkdownURL(for: incoming, registryURL: registryURL)) == nil {
            incoming.file = ""
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
            incoming.localID = incoming.localID ?? existing.localID
            incoming.version = max(incoming.version, existing.version)
            incoming.ownerEmail = incoming.ownerEmail ?? hydratedArchive[index].ownerEmail
            incoming.content = incoming.content ?? hydratedArchive[index].content
            if incoming.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                incoming.trigger = hydratedArchive[index].trigger
            }
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
        var candidate = "\(AgentContextLayout.instructionsDirectoryName)/\(base).md"
        var suffix = 2

        while existingPaths.contains(candidate) {
            candidate = "\(AgentContextLayout.instructionsDirectoryName)/\(base)-\(suffix).md"
            suffix += 1
        }

        return candidate
    }

    private func writeMarkdown(for spell: Spell, registryURL _: URL) throws {
        let markdownURL = versionedMarkdownURL(for: spell)
        try FileManager.default.createDirectory(
            at: markdownURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let markdown = spell.content ?? "# \(spell.name)\n\n\(spell.description)\n\n## Trigger\n\n\(spell.trigger)\n"
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
        guard let markdownURL = try? legacyMarkdownURL(for: placeholder, registryURL: registryURL),
              FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)) else {
            return
        }

        try FileManager.default.removeItem(at: markdownURL)
    }

    private func versionedMarkdownContent(for spell: Spell) -> String? {
        let markdownURL = versionedMarkdownURL(for: spell)
        guard FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)) else {
            return nil
        }

        return try? String(contentsOf: markdownURL, encoding: .utf8)
    }

    private func legacyMarkdownContent(for spell: Spell, registryURL: URL) -> String? {
        guard let markdownURL = try? legacyMarkdownURL(for: spell, registryURL: registryURL),
              FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)) else {
            return nil
        }

        return try? String(contentsOf: markdownURL, encoding: .utf8)
    }

    private func versionedMarkdownURL(for spell: Spell) -> URL {
        SpellbookUserStoreLayout.specURL(storageID: spell.storageID, version: spell.normalizedVersion)
    }

    private func legacyMarkdownURL(for spell: Spell, registryURL: URL) throws -> URL {
        let trimmedFile = spell.file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFile.isEmpty, !trimmedFile.hasPrefix("/") else {
            throw SpellbookError.message("The registry contains an invalid instruction file path.")
        }

        let parts = trimmedFile.split(separator: "/").map(String.init)
        guard parts.count == 2,
              parts[0] == AgentContextLayout.instructionsDirectoryName,
              parts[1].hasSuffix(".md"),
              !parts[1].contains("..") else {
            throw SpellbookError.message("Instruction files must live under .agent-context/instructions and end in .md.")
        }

        return agentContextPackageURL(for: registryURL)
            .appending(path: AgentContextLayout.instructionsDirectoryName, directoryHint: .isDirectory)
            .appending(path: parts[1])
    }

    private func agentContextPackageURL(for registryURL: URL) -> URL {
        let parentURL = registryURL.deletingLastPathComponent()
        if parentURL.lastPathComponent == AgentContextLayout.registryDirectoryName {
            return parentURL.deletingLastPathComponent()
        }
        return parentURL
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

    private func startAccessing(_ url: URL) {
        if scopedURL != url {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = url
            _ = url.startAccessingSecurityScopedResource()
        }
    }

    private func stopAccessingRemovedTarget(_ url: URL) {
        if scopedURL == url {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
    }
}
