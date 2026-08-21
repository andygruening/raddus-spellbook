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
        directoryBookmarkData: Data = Data(),
        addedAt: String = ISO8601DateFormatter.spellbook.string(from: Date())
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SpellbookTarget.displayName(for: directoryPath)
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.directoryPath = directoryPath
        self.harnesses = harnesses
        self.directoryBookmarkData = directoryBookmarkData
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath)
            ?? container.decode(String.self, forKey: .root)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? directoryPath
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? SpellbookTarget.displayName(for: directoryPath)
        directoryBookmarkData = try container.decodeIfPresent(Data.self, forKey: .directoryBookmarkData) ?? Data()
        addedAt = try container.decodeIfPresent(String.self, forKey: .addedAt)
            ?? ISO8601DateFormatter.spellbook.string(from: Date())

        if let decodedHarnesses = try container.decodeIfPresent([SpellbookHarness].self, forKey: .harnesses),
           !decodedHarnesses.isEmpty {
            harnesses = decodedHarnesses
        } else if let decodedFiles = try container.decodeIfPresent([String].self, forKey: .harnessFiles),
                  !decodedFiles.isEmpty {
            harnesses = decodedFiles.map { SpellbookHarness(file: $0) }
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
        guard !directoryBookmarkData.isEmpty else {
            return URL(fileURLWithPath: directoryPath, isDirectory: true)
        }

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

    static func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case directoryPath
        case root
        case instructionFileName
        case harnesses
        case harnessFiles = "harness_files"
        case directoryBookmarkData
        case addedAt
    }
}

private struct LocalInstructionScan {
    var spells: [Spell]
    var diagnostics: [SpellbookDiagnostic]
}

private struct ProjectInstructionState {
    var refsByTargetID: [String: [TargetInstructionRef]]
    var spellsByTargetID: [String: [Spell]]
}

@MainActor
final class LocalSpellStore: ObservableObject {
    @Published private(set) var targets: [SpellbookTarget] = []
    @Published private(set) var spells: [Spell] = []
    @Published private(set) var projectSpellsByTargetID: [String: [Spell]] = [:]
    @Published private(set) var projectInstructionRefsByTargetID: [String: [TargetInstructionRef]] = [:]
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
        SpellbookUserStoreLayout.rulesDirectoryURL
    }

    var latestSpells: [Spell] {
        var latest: [Spell] = []
        var indexesByUID: [String: Int] = [:]

        for spell in spells {
            guard let uid = spell.uid else {
                latest.append(spell)
                continue
            }

            if let index = indexesByUID[uid] {
                if spell.normalizedVersion > latest[index].normalizedVersion {
                    latest[index] = spell
                }
            } else {
                indexesByUID[uid] = latest.count
                latest.append(spell)
            }
        }

        return latest
    }

    func projectSpells(for target: SpellbookTarget) -> [Spell] {
        projectSpellsByTargetID[target.id] ?? []
    }

    func latestInstalledSpell(for spell: Spell) -> Spell? {
        guard let uid = spell.uid else {
            return nil
        }

        return spells
            .filter { candidate in
                candidate.uid == uid && candidate.normalizedVersion > spell.normalizedVersion
            }
            .max { left, right in
                left.normalizedVersion < right.normalizedVersion
            }
    }

    func target(_ target: SpellbookTarget, contains spell: Spell) -> Bool {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            return projectSpells(for: target).contains { projectSpell in
                projectSpell.hasSameIdentity(as: spell)
            }
        }

        return projectInstructionRefsByTargetID[target.id]?.contains { $0.uid == uid } == true
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
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        startAccessing(directoryURL)
        try InstructionManager.apply(directoryURL: directoryURL, harnessFileNames: harnessFileNames, installedSpells: spells)

        if let existingIndex = targets.firstIndex(where: { $0.directoryPath == directoryPath }) {
            let existing = targets[existingIndex]
            targets[existingIndex] = SpellbookTarget(
                id: existing.id,
                name: targetName.isEmpty ? existing.name : targetName,
                directoryPath: directoryPath,
                harnesses: mergedHarnesses(existing.harnesses, harnesses),
                directoryBookmarkData: bookmarkData,
                addedAt: existing.addedAt
            )
        } else {
            targets.append(SpellbookTarget(
                id: directoryPath,
                name: targetName,
                directoryPath: directoryPath,
                harnesses: harnesses,
                directoryBookmarkData: bookmarkData
            ))
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
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let oldDirectoryURL = resolveDirectoryURL(for: target),
           oldDirectoryURL.standardizedFileURL == directoryURL.standardizedFileURL {
            let removedHarnesses = target.harnesses.filter { oldHarness in
                !harnesses.contains(where: { $0.file == oldHarness.file })
            }
            try InstructionManager.removeManagedBlocks(from: oldDirectoryURL, harnesses: removedHarnesses)
        }

        targets[index] = SpellbookTarget(
            id: target.id,
            name: targetName,
            directoryPath: directoryPath,
            harnesses: harnesses,
            directoryBookmarkData: bookmarkData,
            addedAt: target.addedAt
        )

        startAccessing(directoryURL)
        try InstructionManager.apply(directoryURL: directoryURL, harnessFileNames: harnessFileNames, installedSpells: spells)
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
            throw SpellbookError.message("Choose the workspace directory again before removing it.")
        }

        try InstructionManager.removeManagedBlocks(from: directoryURL, harnesses: target.harnesses)
        targets.remove(at: index)
        stopAccessingRemovedTarget(directoryURL)

        try persistTargets()
        try refresh()
    }

    func refresh() throws {
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.rulesDirectoryURL, withIntermediateDirectories: true)
        try migrateLegacySystemRegistryIfNeeded()
        try migrateSandboxedSystemStoreIfNeeded()
        try migrateLegacyInstalledRuleStoresIfNeeded()
        if !FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.targetsURL.path(percentEncoded: false)) {
            try writeKnownTargets()
        }

        let localScan = try scanInstructionStore()
        spells = localScan.spells
        let projectState = try loadProjectInstructionState(systemSpells: spells)
        projectInstructionRefsByTargetID = projectState.refsByTargetID
        projectSpellsByTargetID = projectState.spellsByTargetID
        diagnostics = localScan.diagnostics + (try scanKnownTargets(systemSpells: spells))
        statusMessage = "Loaded \(spells.count) installed rule\(spells.count == 1 ? "" : "s")."
    }

    func repairSystemStore() throws {
        try refresh()
        statusMessage = "Repaired \(SpellbookUserStoreLayout.rootURL.path(percentEncoded: false))."
    }

    func upsertLocal(_ spell: Spell) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Create or sync this rule before installing it locally.")
        }

        var incoming = spell
        incoming.uid = uid
        incoming.localID = nil
        incoming.file = ""
        incoming.version = incoming.normalizedVersion

        if let existing = versionedMetadata(for: incoming) {
            incoming.ownerEmail = incoming.ownerEmail ?? existing.ownerEmail
            incoming.publishedAt = incoming.publishedAt ?? existing.publishedAt
        }

        rememberOwner(for: incoming)
        try writeMetadata(for: incoming)
        try writeMarkdown(for: incoming)
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
        statusMessage = "Installed rule \(installed.name)."
    }

    func removeLocal(_ spell: Spell) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Only uid-backed rules can be removed from the local rule store.")
        }

        try refresh()
        let connectedTargets = projectTargets(containing: spell)
        guard connectedTargets.isEmpty else {
            let projectNames = connectedTargets.map(\.name).joined(separator: ", ")
            throw SpellbookError.message("Remove this rule from \(projectNames) before deleting its local files.")
        }

        let instructionDirectoryURL = SpellbookUserStoreLayout.rulesDirectoryURL
            .appending(path: SpellbookUserStoreLayout.safeStoragePathComponent(uid), directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: instructionDirectoryURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: instructionDirectoryURL)
        }

        try refresh()
        statusMessage = "Removed all local versions of \(spell.name)."
    }

    func createEmptyRegistryIfMissing() throws {
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.rulesDirectoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.targetsURL.path(percentEncoded: false)) {
            try writeKnownTargets()
        }
    }

    func addToTarget(_ spell: Spell, target: SpellbookTarget) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Create or sync this rule before adding it to a workspace.")
        }

        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the workspace directory again before adding rules.")
        }

        try ensureLocalVersionIsComplete(uid: uid, version: spell.normalizedVersion)
        try ensureHarnessBlocks(for: target, directoryURL: directoryURL)

        var replacedExistingVersion = false
        var inserted = false
        for harness in target.harnesses {
            let mutation = try InstructionManager.upsertInstruction(spell, in: directoryURL.appending(path: harness.file))
            replacedExistingVersion = replacedExistingVersion || mutation.replacedExistingVersion
            inserted = inserted || mutation.inserted
        }

        try refresh()
        statusMessage = replacedExistingVersion
            ? "Updated \(spell.name) in \(target.name) to version \(spell.normalizedVersion)."
            : inserted ? "Added \(spell.name) to \(target.name)." : "\(spell.name) is already added to \(target.name)."
    }

    func updateTargetInstruction(_ spell: Spell, target: SpellbookTarget) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("That rule is not uid-backed.")
        }

        guard let latestSpell = latestInstalledSpell(for: spell) else {
            throw SpellbookError.message("No newer installed version is available for \(spell.name).")
        }

        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the workspace directory again before updating rules.")
        }

        try ensureLocalVersionIsComplete(uid: uid, version: latestSpell.normalizedVersion)
        try ensureHarnessBlocks(for: target, directoryURL: directoryURL)
        var updated = false

        for harness in target.harnesses {
            let harnessURL = directoryURL.appending(path: harness.file)
            let refs = try InstructionManager.instructionRefs(in: harnessURL)
            guard refs.contains(where: { $0.uid == uid }) else {
                continue
            }

            _ = try InstructionManager.upsertInstruction(latestSpell, in: harnessURL)
            updated = true
        }

        guard updated else {
            throw SpellbookError.message("That rule is not installed in this workspace.")
        }

        try refresh()
        statusMessage = "Updated \(spell.name) in \(target.name) to version \(latestSpell.normalizedVersion)."
    }

    func removeFromTarget(_ spell: Spell, target: SpellbookTarget) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("That rule is not installed in this workspace.")
        }

        guard let directoryURL = resolveDirectoryURL(for: target) else {
            throw SpellbookError.message("Choose the workspace directory again before removing rules.")
        }

        var removed = false
        for harness in target.harnesses {
            let harnessURL = directoryURL.appending(path: harness.file)
            removed = (try InstructionManager.removeInstruction(uid: uid, from: harnessURL)) || removed
        }

        guard removed else {
            throw SpellbookError.message("That rule is not installed in this workspace.")
        }

        try refresh()
        statusMessage = "Removed \(spell.name) from \(target.name)."
    }

    func installedVersion(uid: String, in target: SpellbookTarget) -> Int? {
        projectInstructionRefsByTargetID[target.id]?.first(where: { $0.uid == uid })?.version
    }

    func installPackRules(_ rules: [Spell], into target: SpellbookTarget) throws {
        guard !rules.isEmpty else {
            throw SpellbookError.message("This pack does not include any rules.")
        }

        for rule in rules {
            try upsertLocal(rule)
            try addToTarget(rule, target: target)
        }

        try refresh()
        statusMessage = "Installed \(rules.count) rule\(rules.count == 1 ? "" : "s") in \(target.name)."
    }

    private func loadSystemRegistry() throws -> SpellRegistry {
        try loadRegistryIfExists(at: SpellbookUserStoreLayout.legacySystemRegistryURL)
    }

    private func loadRegistryIfExists(at url: URL) throws -> SpellRegistry {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .empty
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.spellbook.decode(SpellRegistry.self, from: data)
    }

    private func loadProjectInstructionState(systemSpells: [Spell]) throws -> ProjectInstructionState {
        let index = systemSpells.compactMap { spell -> (String, Spell)? in
            guard let uid = spell.uid else {
                return nil
            }
            return (TargetInstructionRef(uid: uid, version: spell.normalizedVersion).id, spell)
        }
        .reduce(into: [String: Spell]()) { result, pair in
            result[pair.0] = pair.1
        }

        var refsByTargetID: [String: [TargetInstructionRef]] = [:]
        var spellsByTargetID: [String: [Spell]] = [:]

        for target in targets {
            guard let directoryURL = resolveDirectoryURL(for: target) else {
                refsByTargetID[target.id] = []
                spellsByTargetID[target.id] = []
                continue
            }

            var refs: [TargetInstructionRef] = []
            for harness in target.harnesses {
                let harnessURL = directoryURL.appending(path: harness.file)
                refs.append(contentsOf: try InstructionManager.instructionRefs(in: harnessURL))
            }

            var seenRefs: Set<TargetInstructionRef> = []
            let uniqueRefs = refs.filter { ref in
                seenRefs.insert(ref).inserted
            }
            refsByTargetID[target.id] = uniqueRefs
            spellsByTargetID[target.id] = uniqueRefs.compactMap { index[$0.id] }
        }

        return ProjectInstructionState(refsByTargetID: refsByTargetID, spellsByTargetID: spellsByTargetID)
    }

    private func ensureHarnessBlocks(for target: SpellbookTarget, directoryURL: URL) throws {
        try InstructionManager.apply(directoryURL: directoryURL, harnessFileNames: target.harnesses.map(\.file), installedSpells: spells)
    }

    private func ensureLocalVersionIsComplete(uid: String, version: Int) throws {
        let indexURL = SpellbookUserStoreLayout.instructionIndexURL(uid: uid, version: version)
        let specURL = SpellbookUserStoreLayout.specURL(uid: uid, version: version)
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)),
              FileManager.default.fileExists(atPath: specURL.path(percentEncoded: false)) else {
            throw SpellbookError.message("Sync \(uid)@\(version) before adding it to a workspace.")
        }
    }

    private func hydrate(_ spells: [Spell]) -> [Spell] {
        spells.compactMap { spell in
            guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                return nil
            }

            var hydrated = versionedMetadata(for: spell) ?? spell
            hydrated.uid = uid
            hydrated.localID = nil
            hydrated.file = ""
            hydrated.version = spell.normalizedVersion

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

    private func writeMetadata(for spell: Spell) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Only uid-backed rules can be written to the local rule store.")
        }

        let indexURL = SpellbookUserStoreLayout.instructionIndexURL(uid: uid, version: spell.normalizedVersion)
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.spellbook.encode(spell)
        try data.write(to: indexURL, options: [.atomic])
    }

    private func writeMarkdown(for spell: Spell) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Only uid-backed rules can be written to the local rule store.")
        }

        let markdownURL = SpellbookUserStoreLayout.specURL(uid: uid, version: spell.normalizedVersion)
        try FileManager.default.createDirectory(at: markdownURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let markdown = spell.content ?? "# \(spell.name)\n\n\(spell.description)\n\n## Applies When\n\n\(spell.trigger)\n"
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    }

    private func versionedMetadata(for spell: Spell) -> Spell? {
        guard let uid = spell.uid else {
            return nil
        }

        let indexURL = SpellbookUserStoreLayout.instructionIndexURL(uid: uid, version: spell.normalizedVersion)
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: indexURL),
              var metadata = try? JSONDecoder.spellbook.decode(Spell.self, from: data) else {
            return nil
        }

        metadata.uid = uid
        metadata.localID = nil
        metadata.version = spell.normalizedVersion
        return metadata
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

    private func scanInstructionStore() throws -> LocalInstructionScan {
        let now = ISO8601DateFormatter.spellbook.string(from: Date())
        var scannedSpells: [Spell] = []
        var scanDiagnostics: [SpellbookDiagnostic] = []
        let rootURL = SpellbookUserStoreLayout.rulesDirectoryURL

        guard FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)) else {
            return LocalInstructionScan(spells: [], diagnostics: [])
        }

        let uidDirectories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for uidDirectory in uidDirectories where uidDirectory.spellbookIsDirectory {
            let pathUID = uidDirectory.lastPathComponent
            let versionDirectories = try FileManager.default.contentsOfDirectory(
                at: uidDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for versionDirectory in versionDirectories where versionDirectory.spellbookIsDirectory {
                guard let pathVersion = Int(versionDirectory.lastPathComponent), pathVersion > 0 else {
                    continue
                }

                let indexURL = versionDirectory.appending(path: SpellbookUserStoreLayout.instructionIndexFileName)
                let specURL = versionDirectory.appending(path: SpellbookUserStoreLayout.specFileName)
                let hasIndex = FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false))
                let hasSpec = FileManager.default.fileExists(atPath: specURL.path(percentEncoded: false))

                guard hasIndex, hasSpec else {
                    scanDiagnostics.append(SpellbookDiagnostic(
                        type: "incomplete_rule_version",
                        severity: "warning",
                        targetRoot: nil,
                        agent: nil,
                        uid: pathUID,
                        version: pathVersion,
                        message: "\(pathUID)@\(pathVersion) is missing \(hasIndex ? "SPEC.md" : hasSpec ? "index.json" : "index.json and SPEC.md").",
                        detectedAt: now
                    ))
                    continue
                }

                do {
                    let data = try Data(contentsOf: indexURL)
                    var spell = try JSONDecoder.spellbook.decode(Spell.self, from: data)
                    let metadataUID = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines)
                    spell.uid = metadataUID?.isEmpty == false ? metadataUID : pathUID
                    spell.localID = nil
                    spell.file = ""
                    if spell.normalizedVersion != pathVersion {
                        scanDiagnostics.append(SpellbookDiagnostic(
                        type: "rule_metadata_mismatch",
                            severity: "warning",
                            targetRoot: nil,
                            agent: nil,
                            uid: spell.uid,
                            version: pathVersion,
                            message: "\(pathUID)@\(pathVersion) has index.json version \(spell.normalizedVersion).",
                            detectedAt: now
                        ))
                    }
                    spell.version = pathVersion
                    spell.content = try String(contentsOf: specURL, encoding: .utf8)
                    if spell.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        spell.trigger = Spell.trigger(from: spell.content ?? "") ?? ""
                    }
                    if let uid = spell.uid, spell.ownerEmail == nil {
                        spell.ownerEmail = ownerEmail(for: uid)
                    }
                    scannedSpells.append(spell)
                } catch {
                    scanDiagnostics.append(SpellbookDiagnostic(
                        type: "malformed_rule_metadata",
                        severity: "warning",
                        targetRoot: nil,
                        agent: nil,
                        uid: pathUID,
                        version: pathVersion,
                        message: "\(pathUID)@\(pathVersion) has unreadable index.json metadata.",
                        detectedAt: now
                    ))
                }
            }
        }

        scannedSpells.sort {
            if ($0.uid ?? "") == ($1.uid ?? "") {
                return $0.normalizedVersion > $1.normalizedVersion
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return LocalInstructionScan(spells: scannedSpells, diagnostics: scanDiagnostics)
    }

    private func migrateLegacySystemRegistryIfNeeded() throws {
        let sourceURLs = [
            SpellbookUserStoreLayout.legacyLibraryURL,
            SpellbookUserStoreLayout.legacySystemRegistryURL
        ]

        for sourceURL in sourceURLs where FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) {
            let registry = try loadRegistryIfExists(at: sourceURL)
            for spell in hydrate(registry.spells) {
                try migrateLegacySpellIfComplete(spell)
            }
        }
    }

    private func migrateLegacyInstalledRuleStoresIfNeeded() throws {
        let legacyRoots = [
            SpellbookUserStoreLayout.instructionsDirectoryURL,
            SpellbookUserStoreLayout.legacySpellsDirectoryURL
        ]

        for legacyRoot in legacyRoots where FileManager.default.fileExists(atPath: legacyRoot.path(percentEncoded: false)) {
            let uidDirectories = try FileManager.default.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for uidDirectory in uidDirectories where uidDirectory.spellbookIsDirectory {
                let pathUID = uidDirectory.lastPathComponent
                let versionDirectories = try FileManager.default.contentsOfDirectory(
                    at: uidDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                for versionDirectory in versionDirectories where versionDirectory.spellbookIsDirectory {
                    guard let pathVersion = Int(versionDirectory.lastPathComponent), pathVersion > 0 else {
                        continue
                    }

                    let indexURL = versionDirectory.appending(path: SpellbookUserStoreLayout.instructionIndexFileName)
                    let specURL = versionDirectory.appending(path: SpellbookUserStoreLayout.specFileName)
                    guard FileManager.default.fileExists(atPath: specURL.path(percentEncoded: false)) else {
                        continue
                    }

                    let canonicalIndexURL = SpellbookUserStoreLayout.instructionIndexURL(uid: pathUID, version: pathVersion)
                    let canonicalSpecURL = SpellbookUserStoreLayout.specURL(uid: pathUID, version: pathVersion)
                    if FileManager.default.fileExists(atPath: canonicalIndexURL.path(percentEncoded: false)),
                       FileManager.default.fileExists(atPath: canonicalSpecURL.path(percentEncoded: false)) {
                        continue
                    }

                    let content = try String(contentsOf: specURL, encoding: .utf8)
                    var spell: Spell
                    if FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)),
                       let data = try? Data(contentsOf: indexURL),
                       let decoded = try? JSONDecoder.spellbook.decode(Spell.self, from: data) {
                        spell = decoded
                    } else {
                        spell = Spell(
                            uid: pathUID,
                            name: pathUID,
                            description: "Migrated legacy rule.",
                            trigger: Spell.trigger(from: content) ?? "",
                            content: content,
                            version: pathVersion
                        )
                    }

                    spell.uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? spell.uid : pathUID
                    spell.localID = nil
                    spell.file = ""
                    spell.version = pathVersion
                    spell.content = content
                    if spell.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        spell.trigger = Spell.trigger(from: content) ?? ""
                    }

                    rememberOwner(for: spell)
                    try writeMetadata(for: spell)
                    try writeMarkdown(for: spell)
                }
            }
        }
    }

    private func migrateSandboxedSystemStoreIfNeeded() throws {
        guard let sandboxRootURL = SpellbookUserStoreLayout.sandboxContainerRootURL,
              FileManager.default.fileExists(atPath: sandboxRootURL.path(percentEncoded: false)) else {
            return
        }

        let registryURL = sandboxRootURL
            .appending(path: SpellbookUserStoreLayout.registryDirectoryName, directoryHint: .isDirectory)
            .appending(path: SpellbookUserStoreLayout.legacySystemRegistryFileName)
        let legacyLibraryURL = sandboxRootURL
            .appending(path: SpellbookUserStoreLayout.registryDirectoryName, directoryHint: .isDirectory)
            .appending(path: SpellbookUserStoreLayout.legacyLibraryFileName)
        let sourceURL = FileManager.default.fileExists(atPath: registryURL.path(percentEncoded: false)) ? registryURL : legacyLibraryURL

        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return
        }

        let sandboxRegistry = try loadRegistryIfExists(at: sourceURL)
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
            try migrateLegacySpellIfComplete(incoming)
        }
    }

    private func migrateLegacySpellIfComplete(_ spell: Spell) throws {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            return
        }

        var incoming = spell
        incoming.uid = uid
        incoming.localID = nil
        incoming.file = ""
        incoming.version = incoming.normalizedVersion
        incoming.content = incoming.content ?? legacyMarkdownContent(for: spell)

        let hasUsableMetadata = !incoming.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !incoming.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !incoming.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasUsableMetadata || incoming.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }

        rememberOwner(for: incoming)
        try writeMetadata(for: incoming)
        try writeMarkdown(for: incoming)
    }

    private func legacyMarkdownContent(for spell: Spell) -> String? {
        let storageID = spell.uid ?? spell.localID ?? Spell.slug(for: spell.name)
        let candidateURLs = [
            SpellbookUserStoreLayout.legacyInstructionSpecURL(uid: storageID, version: spell.normalizedVersion),
            SpellbookUserStoreLayout.legacySpecURL(storageID: storageID, version: spell.normalizedVersion)
        ]

        for legacyURL in candidateURLs where FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) {
            return try? String(contentsOf: legacyURL, encoding: .utf8)
        }

        return spell.content
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

        let rulesURLs = spell.uid.map { uid in
            sandboxRootURL
                .appending(path: SpellbookUserStoreLayout.rulesDirectoryName, directoryHint: .isDirectory)
                .appending(path: SpellbookUserStoreLayout.safeStoragePathComponent(uid), directoryHint: .isDirectory)
                .appending(path: "\(version)", directoryHint: .isDirectory)
                .appending(path: SpellbookUserStoreLayout.specFileName)
        }.map { [$0] } ?? []

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

        return rulesURLs + instructionsURLs + legacyURLs
    }

    private func scanKnownTargets(systemSpells: [Spell]) throws -> [SpellbookDiagnostic] {
        let now = ISO8601DateFormatter.spellbook.string(from: Date())
        var warnings: [SpellbookDiagnostic] = []
        let spellsByRef = systemSpells.compactMap { spell -> (String, Spell)? in
            guard let uid = spell.uid else {
                return nil
            }
            return (TargetInstructionRef(uid: uid, version: spell.normalizedVersion).id, spell)
        }
        .reduce(into: [String: Spell]()) { result, pair in
            result[pair.0] = pair.1
        }

        for target in targets {
            let directoryExists = FileManager.default.fileExists(atPath: target.directoryPath)
            guard directoryExists else {
            warnings.append(SpellbookDiagnostic(
                type: "stale_target",
                    severity: "warning",
                    targetRoot: target.directoryPath,
                    agent: nil,
                    uid: nil,
                    version: nil,
                message: "The workspace path no longer exists. Relink the workspace or remove it.",
                    detectedAt: now
                ))
                continue
            }

            guard let directoryURL = resolveDirectoryURL(for: target) else {
                warnings.append(SpellbookDiagnostic(
                    type: "target_access_failed",
                    severity: "warning",
                    targetRoot: target.directoryPath,
                    agent: nil,
                    uid: nil,
                    version: nil,
                    message: "Spellbook cannot access the workspace directory. Choose it again in the app.",
                    detectedAt: now
                ))
                continue
            }

            let packageURL = AgentContextLayout.packageURL(in: directoryURL)
            if FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)) {
                warnings.append(SpellbookDiagnostic(
                    type: "legacy_agent_context_package_present",
                    severity: "warning",
                    targetRoot: target.directoryPath,
                    agent: nil,
                    uid: nil,
                    version: nil,
                    message: ".agent-context is no longer used. Repair or update the target to migrate entries into harness files.",
                    detectedAt: now
                ))
            }

            for harness in target.harnesses {
                let harnessURL = directoryURL.appending(path: harness.file)
                guard FileManager.default.fileExists(atPath: harnessURL.path(percentEncoded: false)) else {
                    warnings.append(SpellbookDiagnostic(
                        type: "harness_missing",
                        severity: "warning",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: nil,
                        version: nil,
                        message: "\(harness.file) is missing. Recreate the harness file or remove it from this target.",
                        detectedAt: now
                    ))
                    continue
                }

                let content = try String(contentsOf: harnessURL, encoding: .utf8)
                let parseResult = InstructionManager.parseManagedBlock(in: content)
                guard parseResult.hasManagedBlock else {
                    warnings.append(SpellbookDiagnostic(
                        type: "managed_block_missing",
                        severity: "warning",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: nil,
                        version: nil,
                        message: "\(harness.file) does not contain the Spellbook managed block.",
                        detectedAt: now
                    ))
                    warnings.append(contentsOf: parseResult.issues.map { issue in
                        diagnostic(from: issue, target: target, harness: harness, detectedAt: now)
                    })
                    continue
                }

                warnings.append(contentsOf: parseResult.issues.map { issue in
                    diagnostic(from: issue, target: target, harness: harness, detectedAt: now)
                })

                var seenUIDs: Set<String> = []
                var duplicateUIDs: Set<String> = []
                for entry in parseResult.entries {
                    if !seenUIDs.insert(entry.uid).inserted {
                        duplicateUIDs.insert(entry.uid)
                    }
                }

                for duplicateUID in duplicateUIDs.sorted() {
                    warnings.append(SpellbookDiagnostic(
                        type: "duplicate_rule_entry",
                        severity: "warning",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: duplicateUID,
                        version: nil,
                        message: "\(harness.file) contains duplicate Spellbook entries for \(duplicateUID).",
                        detectedAt: now
                    ))
                }

                if parseResult.issues.isEmpty,
                   let block = parseResult.block,
                   let expectedBlock = InstructionManager.expectedManagedBlock(
                    for: parseResult.entries.map(\.ref),
                    spellsByRef: spellsByRef
                   ),
                   block.trimmingCharacters(in: .whitespacesAndNewlines) != expectedBlock.trimmingCharacters(in: .whitespacesAndNewlines) {
                    warnings.append(SpellbookDiagnostic(
                        type: "managed_block_mismatch",
                        severity: "warning",
                        targetRoot: target.directoryPath,
                        agent: harness.agent,
                        uid: nil,
                        version: nil,
                        message: "\(harness.file)'s Spellbook block differs from the managed template or local rule metadata.",
                        detectedAt: now
                    ))
                }

                for entry in parseResult.entries {
                    let ref = entry.ref
                    if spellsByRef[ref.id] == nil {
                        warnings.append(SpellbookDiagnostic(
                            type: "missing_rule_version",
                            severity: "warning",
                            targetRoot: target.directoryPath,
                            agent: harness.agent,
                            uid: ref.uid,
                            version: ref.version,
                            message: "Workspace references \(ref.uid)@\(ref.version), but that complete local rule version is not installed.",
                            detectedAt: now
                        ))
                    }

                    let indexURL = SpellbookUserStoreLayout.instructionIndexURL(uid: ref.uid, version: ref.version)
                    if !FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) {
                        warnings.append(SpellbookDiagnostic(
                            type: "missing_rule_metadata",
                            severity: "warning",
                            targetRoot: target.directoryPath,
                            agent: harness.agent,
                            uid: ref.uid,
                            version: ref.version,
                            message: "Workspace references \(ref.uid)@\(ref.version), but its index.json metadata is missing.",
                            detectedAt: now
                        ))
                    }

                    let specURL = SpellbookUserStoreLayout.specURL(uid: ref.uid, version: ref.version)
                    if !FileManager.default.fileExists(atPath: specURL.path(percentEncoded: false)) {
                        warnings.append(SpellbookDiagnostic(
                            type: "missing_rule_spec",
                            severity: "warning",
                            targetRoot: target.directoryPath,
                            agent: harness.agent,
                            uid: ref.uid,
                            version: ref.version,
                            message: "Workspace references \(ref.uid)@\(ref.version), but its SPEC.md is missing.",
                            detectedAt: now
                        ))
                    }
                }
            }
        }

        try writeKnownTargets()
        return warnings
    }

    private func diagnostic(
        from issue: HarnessInstructionIssue,
        target: SpellbookTarget,
        harness: SpellbookHarness,
        detectedAt: String
    ) -> SpellbookDiagnostic {
        SpellbookDiagnostic(
            type: issue.type,
            severity: "warning",
            targetRoot: target.directoryPath,
            agent: harness.agent,
            uid: issue.uid,
            version: issue.version,
            message: issue.message,
            detectedAt: detectedAt
        )
    }

    private func writeKnownTargets() throws {
        let knownTargets = targets.map { target in
            KnownTarget(root: target.directoryPath, harnessFiles: target.harnesses.map(\.file))
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

        restoreKnownTargetsRegistry()
        restoreLegacyTarget()
    }

    private func restoreKnownTargetsRegistry() {
        guard FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.targetsURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: SpellbookUserStoreLayout.targetsURL),
              let registry = try? JSONDecoder.spellbook.decode(KnownTargetsRegistry.self, from: data) else {
            return
        }

        targets = registry.targets.map { knownTarget in
            SpellbookTarget(
                id: knownTarget.root,
                name: SpellbookTarget.displayName(for: knownTarget.root),
                directoryPath: knownTarget.root,
                harnesses: knownTarget.harnesses
            )
        }
    }

    private func restoreLegacyTarget() {
        guard targets.isEmpty,
              let data = UserDefaults.standard.data(forKey: legacyBookmarkKey) else {
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
        try writeKnownTargets()
    }

    private func mergedHarnesses(_ existingHarnesses: [SpellbookHarness], _ incomingHarnesses: [SpellbookHarness]) -> [SpellbookHarness] {
        let files = Set(existingHarnesses.map(\.file)).union(incomingHarnesses.map(\.file))
        return InstructionManager.supportedFiles
            .filter { files.contains($0) }
            .map { SpellbookHarness(file: $0) }
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
