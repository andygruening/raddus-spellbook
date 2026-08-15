import AppKit
import Foundation

struct SpellbookTarget: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var directoryPath: String
    var harnesses: [SpellbookHarness]
    var directoryBookmarkData: Data
    var addedAt: String

    var displayPath: String {
        let files = harnesses.map(\.file).joined(separator: ", ")
        return "\(directoryPath) (\(files))"
    }

    var instructionFileName: String {
        harnesses.first?.file ?? InstructionManager.supportedFiles[0]
    }

    init(
        id: String,
        name: String,
        directoryPath: String,
        harnesses: [SpellbookHarness],
        directoryBookmarkData: Data,
        addedAt: String = ISO8601DateFormatter.spellbook.string(from: Date())
    ) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
        self.harnesses = harnesses
        self.directoryBookmarkData = directoryBookmarkData
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        directoryPath = try container.decode(String.self, forKey: .directoryPath)
        directoryBookmarkData = try container.decode(Data.self, forKey: .directoryBookmarkData)
        addedAt = try container.decodeIfPresent(String.self, forKey: .addedAt)
            ?? ISO8601DateFormatter.spellbook.string(from: Date())

        if let decodedHarnesses = try container.decodeIfPresent([SpellbookHarness].self, forKey: .harnesses),
           !decodedHarnesses.isEmpty {
            harnesses = decodedHarnesses
        } else {
            let legacyFileName = try container.decodeIfPresent(String.self, forKey: .instructionFileName)
                ?? InstructionManager.supportedFiles[0]
            harnesses = [AgentContextLayout.harness(for: legacyFileName)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(directoryPath, forKey: .directoryPath)
        try container.encode(harnesses, forKey: .harnesses)
        try container.encode(directoryBookmarkData, forKey: .directoryBookmarkData)
        try container.encode(addedAt, forKey: .addedAt)
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

    func registryURL(in directoryURL: URL, agent: String) -> URL {
        AgentContextLayout.registryURL(in: directoryURL, agent: agent)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case directoryPath
        case instructionFileName
        case harnesses
        case directoryBookmarkData
        case addedAt
    }
}

@MainActor
final class LocalSpellStore: ObservableObject {
    @Published private(set) var targets: [SpellbookTarget] = []
    @Published private(set) var spells: [Spell] = []
    @Published private(set) var projectSpellsByTargetID: [String: [Spell]] = [:]
    @Published private(set) var diagnostics: [SpellbookDiagnostic] = []
    @Published var statusMessage: String?
    @Published var lastError: String?

    private let targetsKey = "spellbook.targets"
    private let legacyBookmarkKey = "spellbook.selectedTargetBookmark"
    private let ownerEmailsByUIDKey = "spellbook.ownerEmailsByUID"
    private var scopedURL: URL?

    init() {
        restoreTargets()
        if targets.isEmpty {
            do {
                try refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    var spellsURL: URL? {
        SpellbookUserStoreLayout.systemRegistryURL
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

    func addTarget(directoryURL: URL, harnessFileNames: [String], name: String) throws {
        let harnesses = try InstructionManager.harnesses(for: harnessFileNames)
        let bookmarkData = try directoryURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let directoryPath = directoryURL.path(percentEncoded: false)
        let fallbackName = directoryURL.lastPathComponent.isEmpty ? directoryPath : directoryURL.lastPathComponent
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var incoming = SpellbookTarget(
            id: "target-\(UUID().uuidString)",
            name: targetName,
            directoryPath: directoryPath,
            harnesses: harnesses,
            directoryBookmarkData: bookmarkData
        )

        startAccessing(directoryURL)
        try InstructionManager.apply(directoryURL: directoryURL, harnessFileNames: harnessFileNames)

        if let existingIndex = targets.firstIndex(where: { $0.directoryPath == directoryPath }) {
            incoming.id = targets[existingIndex].id
            incoming.addedAt = targets[existingIndex].addedAt
            targets[existingIndex] = incoming
        } else {
            targets.append(incoming)
        }

        try persistTargets()
        try refresh()
    }

    func addTarget(directoryURL: URL, instructionFileName: String, name: String) throws {
        try addTarget(directoryURL: directoryURL, harnessFileNames: [instructionFileName], name: name)
    }

    func updateTarget(_ target: SpellbookTarget, directoryURL: URL, harnessFileNames: [String], name: String) throws {
        let harnesses = try InstructionManager.harnesses(for: harnessFileNames)
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
            harnesses: harnesses,
            directoryBookmarkData: bookmarkData,
            addedAt: target.addedAt
        )

        startAccessing(directoryURL)
        try InstructionManager.apply(directoryURL: directoryURL, harnessFileNames: harnessFileNames)
        try persistTargets()
        try refresh()
    }

    func updateTarget(_ target: SpellbookTarget, directoryURL: URL, instructionFileName: String, name: String) throws {
        try updateTarget(target, directoryURL: directoryURL, harnessFileNames: [instructionFileName], name: name)
    }

    func removeTarget(_ target: SpellbookTarget) throws {
        guard let index = targets.firstIndex(where: { $0.id == target.id }) else {
            throw SpellbookError.message("That target could not be found.")
        }

        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the target directory again before removing it.")
        }

        try InstructionManager.removeManagedBlocks(from: directoryURL, harnesses: target.harnesses)
        targets.remove(at: index)
        stopAccessingRemovedTarget(directoryURL)

        try persistTargets()
        try refresh()
    }

    func refresh() throws {
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.instructionsDirectoryURL, withIntermediateDirectories: true)
        try InstructionManager.installResolver()
        try migrateLegacySystemRegistryIfNeeded()
        try migrateSandboxedSystemStoreIfNeeded()
        try createEmptyRegistryIfMissing()
        let registry = try loadSystemRegistry()
        spells = hydrate(registry.spells)
        projectSpellsByTargetID = try loadProjectSpellsByTargetID(systemSpells: spells)
        diagnostics = try scanKnownTargetsAndWriteErrors(systemSpells: spells)
        statusMessage = "Loaded \(spells.count) installed instruction\(spells.count == 1 ? "" : "s")."
    }

    func repairSystemStore() throws {
        try refresh()
        statusMessage = "Repaired \(SpellbookUserStoreLayout.rootURL.path(percentEncoded: false))."
    }

    func upsertLocal(_ spell: Spell) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Publish or sync this instruction before installing it locally.")
        }

        var registry = try loadSystemRegistry()
        var incoming = spell
        incoming.uid = uid
        incoming.localID = nil
        incoming.file = ""
        incoming.version = incoming.normalizedVersion

        if let index = registry.spells.firstIndex(where: { $0.uid == uid && $0.normalizedVersion == incoming.normalizedVersion }) {
            incoming.ownerEmail = incoming.ownerEmail ?? registry.spells[index].ownerEmail
            incoming.publishedAt = incoming.publishedAt ?? registry.spells[index].publishedAt
            registry.spells[index] = incoming
        } else {
            registry.spells.insert(incoming, at: 0)
        }

        rememberOwner(for: incoming)
        try writeMarkdown(for: incoming)
        try saveSystemRegistry(registry)
        try refresh()
        statusMessage = "Installed \(incoming.name) \(uid)@\(incoming.normalizedVersion)."
    }

    func updateLocal(_ spell: Spell) throws {
        try upsertLocal(spell)
    }

    func updateAfterPublish(localIdentifier _: String, remoteSpell: Spell, signedInEmail: String) throws {
        var installed = remoteSpell
        installed.ownerEmail = installed.ownerEmail ?? signedInEmail
        try upsertLocal(installed)
        statusMessage = "Installed published instruction \(installed.name)."
    }

    func removeLocal(_ spell: Spell) throws {
        guard let uid = spell.uid else {
            throw SpellbookError.message("Only published instructions can be removed from the installed registry.")
        }

        let connectedTargets = projectTargets(containing: spell)
        guard connectedTargets.isEmpty else {
            let projectNames = connectedTargets.map(\.name).joined(separator: ", ")
            throw SpellbookError.message("Remove this instruction from \(projectNames) before removing it from the installed registry.")
        }

        var registry = try loadSystemRegistry()
        registry.spells.removeAll { $0.uid == uid && $0.normalizedVersion == spell.normalizedVersion }
        try saveSystemRegistry(registry)
        try refresh()
        statusMessage = "Removed \(spell.name)."
    }

    func createEmptyRegistryIfMissing() throws {
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.instructionsDirectoryURL, withIntermediateDirectories: true)
        try InstructionManager.installResolver()

        if !FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.systemRegistryURL.path(percentEncoded: false)) {
            try saveSystemRegistry(.empty)
        }

        if !FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.targetsURL.path(percentEncoded: false)) {
            try writeKnownTargets(lastScannedAt: nil)
        }

        if !FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.errorsURL.path(percentEncoded: false)) {
            try saveErrors(.empty)
        }
    }

    func addToTarget(_ spell: Spell, target: SpellbookTarget) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Publish or sync this instruction before adding it to a target.")
        }

        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the project directory again before adding instructions.")
        }

        try ensureProjectPackage(for: target, directoryURL: directoryURL)
        let ref = TargetInstructionRef(uid: uid, version: spell.normalizedVersion)

        for harness in target.harnesses {
            let registryURL = target.registryURL(in: directoryURL, agent: harness.agent)
            var registry = try loadTargetRegistryIfExists(at: registryURL, agent: harness.agent)
            if !registry.instructions.contains(ref) {
                registry.instructions.insert(ref, at: 0)
                try save(registry, to: registryURL)
            }
        }

        try refresh()
        statusMessage = "Added \(spell.name) to \(target.name)."
    }

    func removeFromTarget(_ spell: Spell, target: SpellbookTarget) throws {
        guard let uid = spell.uid else {
            throw SpellbookError.message("That instruction is not installed in this target.")
        }

        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the project directory again before removing instructions.")
        }

        var removed = false
        for harness in target.harnesses {
            let registryURL = target.registryURL(in: directoryURL, agent: harness.agent)
            var registry = try loadTargetRegistryIfExists(at: registryURL, agent: harness.agent)
            let oldCount = registry.instructions.count
            registry.instructions.removeAll { $0.uid == uid && $0.version == spell.normalizedVersion }
            if registry.instructions.count != oldCount {
                try save(registry, to: registryURL)
                removed = true
            }
        }

        guard removed else {
            throw SpellbookError.message("That instruction is not installed in this project.")
        }

        try refresh()
        statusMessage = "Removed \(spell.name) from \(target.name)."
    }

    private func loadSystemRegistry() throws -> SpellRegistry {
        try loadRegistryIfExists(at: SpellbookUserStoreLayout.systemRegistryURL)
    }

    private func saveSystemRegistry(_ registry: SpellRegistry) throws {
        let data = try JSONEncoder.spellbook.encode(registry)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.systemRegistryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: SpellbookUserStoreLayout.systemRegistryURL, options: [.atomic])
    }

    private func loadRegistryIfExists(at url: URL) throws -> SpellRegistry {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .empty
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.spellbook.decode(SpellRegistry.self, from: data)
    }

    private func loadTargetRegistryIfExists(at url: URL, agent: String) throws -> TargetInstructionRegistry {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .empty(agent: agent)
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.spellbook.decode(TargetInstructionRegistry.self, from: data)
    }

    private func save(_ registry: TargetInstructionRegistry, to url: URL) throws {
        let data = try JSONEncoder.spellbook.encode(registry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func loadProjectSpellsByTargetID(systemSpells: [Spell]) throws -> [String: [Spell]] {
        let index = systemSpells.compactMap { spell -> (String, Spell)? in
            guard let uid = spell.uid else {
                return nil
            }
            return ("\(uid)@\(spell.normalizedVersion)", spell)
        }
        .reduce(into: [String: Spell]()) { result, pair in
            result[pair.0] = pair.1
        }
        var projectSpells: [String: [Spell]] = [:]

        for target in targets {
            guard let directoryURL = resolveDirectoryURL(for: target) else {
                projectSpells[target.id] = []
                continue
            }

            var refs: [TargetInstructionRef] = []
            for harness in target.harnesses {
                let registryURL = target.registryURL(in: directoryURL, agent: harness.agent)
                let registry = try loadTargetRegistryIfExists(at: registryURL, agent: harness.agent)
                refs.append(contentsOf: registry.instructions)
            }

            var seen: Set<TargetInstructionRef> = []
            projectSpells[target.id] = refs.compactMap { ref in
                guard !seen.contains(ref) else {
                    return nil
                }
                seen.insert(ref)
                return index[ref.id]
            }
        }

        return projectSpells
    }

    private func ensureProjectPackage(for target: SpellbookTarget, directoryURL: URL) throws {
        try InstructionManager.apply(directoryURL: directoryURL, harnessFileNames: target.harnesses.map(\.file))
    }

    private func hydrate(_ spells: [Spell]) -> [Spell] {
        spells.compactMap { spell in
            guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                return nil
            }

            var hydrated = spell
            hydrated.uid = uid
            hydrated.localID = nil
            hydrated.file = ""
            hydrated.version = hydrated.normalizedVersion

            if hydrated.ownerEmail == nil {
                hydrated.ownerEmail = ownerEmail(for: uid)
            }

            if let content = versionedMarkdownContent(for: hydrated) {
                hydrated.content = content
                if hydrated.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hydrated.trigger = Spell.trigger(from: content) ?? ""
                }
            }
            return hydrated
        }
    }

    private func writeMarkdown(for spell: Spell) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Only uid-backed instructions can be written to the system instruction store.")
        }

        let markdownURL = SpellbookUserStoreLayout.specURL(uid: uid, version: spell.normalizedVersion)
        try FileManager.default.createDirectory(at: markdownURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let markdown = spell.content ?? "# \(spell.name)\n\n\(spell.description)\n\n## Trigger\n\n\(spell.trigger)\n"
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    }

    private func versionedMarkdownContent(for spell: Spell) -> String? {
        guard let uid = spell.uid else {
            return nil
        }

        let markdownURL = SpellbookUserStoreLayout.specURL(uid: uid, version: spell.normalizedVersion)
        guard FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)) else {
            return nil
        }

        return try? String(contentsOf: markdownURL, encoding: .utf8)
    }

    private func migrateLegacySystemRegistryIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.legacyLibraryURL.path(percentEncoded: false)) else {
            return
        }

        let newRegistryExists = FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.systemRegistryURL.path(percentEncoded: false))
        if newRegistryExists, !(try loadSystemRegistry().spells.isEmpty) {
            return
        }

        let legacy = try loadRegistryIfExists(at: SpellbookUserStoreLayout.legacyLibraryURL)
        var migrated = SpellRegistry.empty
        for spell in legacy.spells {
            guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                continue
            }

            var incoming = spell
            incoming.uid = uid
            incoming.localID = nil
            incoming.file = ""
            incoming.version = incoming.normalizedVersion
            incoming.content = incoming.content ?? legacyMarkdownContent(for: spell)
            migrated.spells.append(incoming)
            rememberOwner(for: incoming)
            try writeMarkdown(for: incoming)
        }

        try saveSystemRegistry(migrated)
    }

    private func migrateSandboxedSystemStoreIfNeeded() throws {
        guard let sandboxRootURL = SpellbookUserStoreLayout.sandboxContainerRootURL,
              FileManager.default.fileExists(atPath: sandboxRootURL.path(percentEncoded: false)),
              (try loadSystemRegistry().spells.isEmpty) else {
            return
        }

        let registryURL = sandboxRootURL
            .appending(path: SpellbookUserStoreLayout.registryDirectoryName, directoryHint: .isDirectory)
            .appending(path: SpellbookUserStoreLayout.registryFileName)
        let legacyLibraryURL = sandboxRootURL
            .appending(path: SpellbookUserStoreLayout.registryDirectoryName, directoryHint: .isDirectory)
            .appending(path: SpellbookUserStoreLayout.legacyLibraryFileName)
        let sourceURL = FileManager.default.fileExists(atPath: registryURL.path(percentEncoded: false)) ? registryURL : legacyLibraryURL

        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return
        }

        let sandboxRegistry = try loadRegistryIfExists(at: sourceURL)
        var migrated = SpellRegistry.empty
        for spell in sandboxRegistry.spells {
            guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                continue
            }

            var incoming = spell
            incoming.uid = uid
            incoming.localID = nil
            incoming.file = ""
            incoming.version = incoming.normalizedVersion
            incoming.content = incoming.content ?? sandboxedMarkdownContent(for: spell, sandboxRootURL: sandboxRootURL)
            migrated.spells.append(incoming)
            rememberOwner(for: incoming)
            try writeMarkdown(for: incoming)
        }

        if !migrated.spells.isEmpty {
            try saveSystemRegistry(migrated)
        }
    }

    private func legacyMarkdownContent(for spell: Spell) -> String? {
        let storageID = spell.uid ?? spell.localID ?? Spell.slug(for: spell.name)
        let legacyURL = SpellbookUserStoreLayout.legacySpecURL(storageID: storageID, version: spell.normalizedVersion)
        guard FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) else {
            return spell.content
        }

        return try? String(contentsOf: legacyURL, encoding: .utf8)
    }

    private func sandboxedMarkdownContent(for spell: Spell, sandboxRootURL: URL) -> String? {
        let candidateURLs = sandboxedMarkdownCandidateURLs(for: spell, sandboxRootURL: sandboxRootURL)
        for candidateURL in candidateURLs where FileManager.default.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
            return try? String(contentsOf: candidateURL, encoding: .utf8)
        }

        return spell.content
    }

    private func sandboxedMarkdownCandidateURLs(for spell: Spell, sandboxRootURL: URL) -> [URL] {
        let version = spell.normalizedVersion
        var storageIDs = [spell.uid, spell.localID, Optional(Spell.slug(for: spell.name))]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        storageIDs = Array(Set(storageIDs))

        let instructionsURLs = spell.uid.map { uid in
            sandboxRootURL
                .appending(path: SpellbookUserStoreLayout.instructionsDirectoryName, directoryHint: .isDirectory)
                .appending(path: SpellbookUserStoreLayout.safeStoragePathComponent(uid), directoryHint: .isDirectory)
                .appending(path: "\(version)", directoryHint: .isDirectory)
                .appending(path: SpellbookUserStoreLayout.specFileName)
        }.map { [$0] } ?? []

        let legacyURLs = storageIDs.map { storageID in
            sandboxRootURL
                .appending(path: SpellbookUserStoreLayout.legacySpellsDirectoryName, directoryHint: .isDirectory)
                .appending(path: SpellbookUserStoreLayout.safeStoragePathComponent(storageID), directoryHint: .isDirectory)
                .appending(path: "\(version)", directoryHint: .isDirectory)
                .appending(path: SpellbookUserStoreLayout.specFileName)
        }

        return instructionsURLs + legacyURLs
    }

    private func scanKnownTargetsAndWriteErrors(systemSpells: [Spell]) throws -> [SpellbookDiagnostic] {
        let now = ISO8601DateFormatter.spellbook.string(from: Date())
        var errors: [SpellbookDiagnostic] = []
        let installedRefs = Set(systemSpells.compactMap { spell -> TargetInstructionRef? in
            guard let uid = spell.uid else {
                return nil
            }
            return TargetInstructionRef(uid: uid, version: spell.normalizedVersion)
        })

        if !FileManager.default.isExecutableFile(atPath: SpellbookUserStoreLayout.resolverURL.path(percentEncoded: false)) {
            errors.append(SpellbookDiagnostic(
                type: "resolver_missing",
                severity: "error",
                targetRoot: nil,
                agent: nil,
                uid: nil,
                version: nil,
                message: "The Spellbook resolver is missing or is not executable.",
                detectedAt: now
            ))
        }

        for target in targets {
            let directoryExists = FileManager.default.fileExists(atPath: target.directoryPath)
            guard directoryExists else {
                errors.append(SpellbookDiagnostic(
                    type: "stale_target",
                    severity: "warning",
                    targetRoot: target.directoryPath,
                    agent: nil,
                    uid: nil,
                    version: nil,
                    message: "The target path no longer exists.",
                    detectedAt: now
                ))
                continue
            }

            guard let directoryURL = resolveDirectoryURL(for: target) else {
                errors.append(SpellbookDiagnostic(
                    type: "target_access_failed",
                    severity: "warning",
                    targetRoot: target.directoryPath,
                    agent: nil,
                    uid: nil,
                    version: nil,
                    message: "Spellbook cannot access the target directory. Choose it again in the app.",
                    detectedAt: now
                ))
                continue
            }

            let manifestURL = AgentContextLayout.manifestURL(in: directoryURL)
            if !FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) {
                errors.append(SpellbookDiagnostic(
                    type: "manifest_missing",
                    severity: "error",
                    targetRoot: target.directoryPath,
                    agent: nil,
                    uid: nil,
                    version: nil,
                    message: ".agent-context/manifest.json is missing.",
                    detectedAt: now
                ))
            } else if (try? JSONDecoder.spellbook.decode(AgentContextManifest.self, from: Data(contentsOf: manifestURL))) == nil {
                errors.append(SpellbookDiagnostic(
                    type: "malformed_manifest",
                    severity: "error",
                    targetRoot: target.directoryPath,
                    agent: nil,
                    uid: nil,
                    version: nil,
                    message: ".agent-context/manifest.json is not valid for the Spellbook resolver.",
                    detectedAt: now
                ))
            }

            for harness in target.harnesses {
                let harnessURL = directoryURL.appending(path: harness.file)
                if !FileManager.default.fileExists(atPath: harnessURL.path(percentEncoded: false)) {
                    errors.append(SpellbookDiagnostic(
                        type: "harness_missing",
                        severity: "warning",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: nil,
                        version: nil,
                        message: "\(harness.file) is missing.",
                        detectedAt: now
                    ))
                } else if (try? String(contentsOf: harnessURL, encoding: .utf8).contains(InstructionManager.startMarker)) != true {
                    errors.append(SpellbookDiagnostic(
                        type: "managed_block_missing",
                        severity: "warning",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: nil,
                        version: nil,
                        message: "\(harness.file) does not contain the Spellbook managed block.",
                        detectedAt: now
                    ))
                }

                let registryURL = target.registryURL(in: directoryURL, agent: harness.agent)
                guard FileManager.default.fileExists(atPath: registryURL.path(percentEncoded: false)) else {
                    errors.append(SpellbookDiagnostic(
                        type: "target_registry_missing",
                        severity: "error",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: nil,
                        version: nil,
                        message: "\(harness.registry) is missing.",
                        detectedAt: now
                    ))
                    continue
                }

                guard let registry = try? loadTargetRegistryIfExists(at: registryURL, agent: harness.agent) else {
                    errors.append(SpellbookDiagnostic(
                        type: "malformed_target_registry",
                        severity: "error",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: nil,
                        version: nil,
                        message: "\(harness.registry) is not valid JSON.",
                        detectedAt: now
                    ))
                    continue
                }

                for ref in registry.instructions {
                    if !installedRefs.contains(ref) {
                        errors.append(SpellbookDiagnostic(
                            type: "missing_instruction_version",
                            severity: "warning",
                            targetRoot: target.directoryPath,
                            agent: harness.agent,
                            uid: ref.uid,
                            version: ref.version,
                            message: "Target references \(ref.uid)@\(ref.version), but that version is not installed.",
                            detectedAt: now
                        ))
                        continue
                    }

                    let specURL = SpellbookUserStoreLayout.specURL(uid: ref.uid, version: ref.version)
                    if !FileManager.default.fileExists(atPath: specURL.path(percentEncoded: false)) {
                        errors.append(SpellbookDiagnostic(
                            type: "missing_instruction_spec",
                            severity: "warning",
                            targetRoot: target.directoryPath,
                            agent: harness.agent,
                            uid: ref.uid,
                            version: ref.version,
                            message: "Target references \(ref.uid)@\(ref.version), but its SPEC.md is missing.",
                            detectedAt: now
                        ))
                    }
                }
            }
        }

        try saveErrors(SpellbookErrorsRegistry(schemaVersion: 1, errors: errors))
        try writeKnownTargets(lastScannedAt: now)
        return errors
    }

    private func saveErrors(_ registry: SpellbookErrorsRegistry) throws {
        let data = try JSONEncoder.spellbook.encode(registry)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.errorsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: SpellbookUserStoreLayout.errorsURL, options: [.atomic])
    }

    private func writeKnownTargets(lastScannedAt: String?) throws {
        let knownTargets = targets.map { target in
            KnownTarget(
                id: target.id,
                targetRoot: target.directoryPath,
                agentContext: "\(AgentContextLayout.packageDirectoryName)/\(AgentContextLayout.manifestFileName)",
                harnesses: target.harnesses,
                addedAt: target.addedAt,
                lastScannedAt: lastScannedAt
            )
        }
        let registry = KnownTargetsRegistry(schemaVersion: 1, targets: knownTargets)
        let data = try JSONEncoder.spellbook.encode(registry)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.targetsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: SpellbookUserStoreLayout.targetsURL, options: [.atomic])
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
                try addTarget(directoryURL: directoryURL, harnessFileNames: [instructionFileName], name: directoryURL.lastPathComponent)
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

    private func persistTargets() throws {
        let data = try JSONEncoder.spellbook.encode(targets)
        UserDefaults.standard.set(data, forKey: targetsKey)
        try writeKnownTargets(lastScannedAt: nil)
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
