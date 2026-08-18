import Darwin
import Foundation

enum AgentContextLayout {
    static let packageDirectoryName = ".agent-context"
    static let instructionsDirectoryName = "instructions"
    static let legacyRegistryFileName = "registry.json"

    static func packageURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: packageDirectoryName, directoryHint: .isDirectory)
    }

    static func legacyRegistryFileName(for agent: String) -> String {
        "\(agent).registry.json"
    }

    static func legacyRegistryURL(in directoryURL: URL, agent: String) -> URL {
        packageURL(in: directoryURL).appending(path: legacyRegistryFileName(for: agent))
    }

    static func agentName(for instructionFileName: String) -> String {
        switch instructionFileName {
        case "CLAUDE.md":
            return "claude"
        case "AGENT.md":
            return "agent"
        default:
            return "codex"
        }
    }

    static func harness(for fileName: String) -> SpellbookHarness {
        SpellbookHarness(file: fileName)
    }

    static func canonicalInstructionFilePath(_ file: String) -> String {
        let trimmedFile = file.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFile.hasPrefix("spells/") {
            return "\(instructionsDirectoryName)/\(trimmedFile.dropFirst("spells/".count))"
        }
        return trimmedFile
    }
}

enum SpellbookUserStoreLayout {
    static let rootDirectoryName = ".spellbook"
    static let registryDirectoryName = "registry"
    static let instructionsDirectoryName = "instructions"
    static let legacySpellsDirectoryName = "spells"
    static let legacySystemRegistryFileName = "registry.json"
    static let legacyLibraryFileName = "library.json"
    static let targetsFileName = "targets.json"
    static let specFileName = "SPEC.md"
    static let instructionIndexFileName = "index.json"

    static var rootURL: URL {
        realHomeDirectoryURL.appending(path: rootDirectoryName, directoryHint: .isDirectory)
    }

    static var sandboxContainerRootURL: URL? {
        let sandboxHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let realHome = realHomeDirectoryURL.standardizedFileURL
        guard sandboxHome.path(percentEncoded: false) != realHome.path(percentEncoded: false) else {
            return nil
        }

        return sandboxHome.appending(path: rootDirectoryName, directoryHint: .isDirectory)
    }

    static var realHomeDirectoryURL: URL {
        if let passwd = getpwuid(getuid()),
           let homeDirectory = passwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: homeDirectory), isDirectory: true)
        }

        let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    static var registryDirectoryURL: URL {
        rootURL.appending(path: registryDirectoryName, directoryHint: .isDirectory)
    }

    static var legacySystemRegistryURL: URL {
        registryDirectoryURL.appending(path: legacySystemRegistryFileName)
    }

    static var legacyLibraryURL: URL {
        registryDirectoryURL.appending(path: legacyLibraryFileName)
    }

    static var targetsURL: URL {
        registryDirectoryURL.appending(path: targetsFileName)
    }

    static var instructionsDirectoryURL: URL {
        rootURL.appending(path: instructionsDirectoryName, directoryHint: .isDirectory)
    }

    static var legacySpellsDirectoryURL: URL {
        rootURL.appending(path: legacySpellsDirectoryName, directoryHint: .isDirectory)
    }

    static func instructionDirectoryURL(uid: String, version: Int) -> URL {
        instructionsDirectoryURL
            .appending(path: safeStoragePathComponent(uid), directoryHint: .isDirectory)
            .appending(path: "\(max(version, 1))", directoryHint: .isDirectory)
    }

    static func specURL(uid: String, version: Int) -> URL {
        instructionDirectoryURL(uid: uid, version: version).appending(path: specFileName)
    }

    static func instructionIndexURL(uid: String, version: Int) -> URL {
        instructionDirectoryURL(uid: uid, version: version).appending(path: instructionIndexFileName)
    }

    static func harnessSpecPath(uid: String, version: Int) -> String {
        "~/\(rootDirectoryName)/\(instructionsDirectoryName)/\(safeStoragePathComponent(uid))/\(max(version, 1))/\(specFileName)"
    }

    static func legacySpecURL(storageID: String, version: Int) -> URL {
        legacySpellsDirectoryURL
            .appending(path: safeStoragePathComponent(storageID), directoryHint: .isDirectory)
            .appending(path: "\(max(version, 1))", directoryHint: .isDirectory)
            .appending(path: specFileName)
    }

    static func safeStoragePathComponent(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safePunctuation = CharacterSet(charactersIn: "-_")
        let scalars = normalized.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || safePunctuation.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "instruction" : collapsed
    }
}

struct HarnessInstructionEntry: Equatable {
    var uid: String
    var version: Int
    var raw: String?

    var ref: TargetInstructionRef {
        TargetInstructionRef(uid: uid, version: version)
    }
}

struct HarnessInstructionIssue: Equatable {
    var type: String
    var message: String
    var uid: String?
    var version: Int?
}

struct HarnessInstructionParseResult: Equatable {
    var hasManagedBlock: Bool
    var block: String?
    var entries: [HarnessInstructionEntry]
    var issues: [HarnessInstructionIssue]
}

struct HarnessInstructionMutation: Equatable {
    var inserted: Bool
    var replacedExistingVersion: Bool
}

enum InstructionManager {
    static let supportedFiles = ["AGENTS.md", "AGENT.md", "CLAUDE.md"]
    static let startMarker = "<!-- spellbook:start -->"
    static let endMarker = "<!-- spellbook:end -->"
    static let instructionStartPrefix = "<!-- spellbook:instruction:start"
    static let instructionEndMarker = "<!-- spellbook:instruction:end -->"

    private static let attributePattern = #"([A-Za-z_][A-Za-z0-9_-]*)="([^"]*)""#

    static func defaultHarnessFileNames(in directoryURL: URL) -> [String] {
        let existing = supportedFiles.filter { fileName in
            FileManager.default.fileExists(atPath: directoryURL.appending(path: fileName).path(percentEncoded: false))
        }
        return existing.isEmpty ? [supportedFiles[0]] : existing
    }

    static func harnesses(for fileNames: [String]) throws -> [SpellbookHarness] {
        let normalizedFiles = fileNames.filter { supportedFiles.contains($0) }
        guard !normalizedFiles.isEmpty else {
            throw SpellbookError.message("Choose at least one supported harness file.")
        }

        var seenFiles: Set<String> = []
        return normalizedFiles.compactMap { fileName in
            guard !seenFiles.contains(fileName) else {
                return nil
            }
            seenFiles.insert(fileName)
            return AgentContextLayout.harness(for: fileName)
        }
    }

    static func preview(selectedURL: URL?, preferredFileName: String) throws -> InstructionPreview {
        guard let selectedURL else {
            throw SpellbookError.message("Choose a directory or instruction file first.")
        }

        let target = try targetInstructionURL(from: selectedURL, preferredFileName: preferredFileName)
        let harness = AgentContextLayout.harness(for: target.lastPathComponent)
        let existingContent = try? String(contentsOf: target, encoding: .utf8)
        let targetExists = existingContent != nil
        let parseResult = parseManagedBlock(in: existingContent ?? "")
        let nextContent = try contentByApplyingManagedBlock(to: existingContent ?? "", entriesToMerge: [])
        let action: ManagedBlockAction = parseResult.hasManagedBlock ? .update : .add

        return InstructionPreview(
            targetInstructionURL: target,
            targetExists: targetExists,
            agent: harness.agent,
            managedInstructionCount: parseResult.entries.count,
            instructionStoreURL: SpellbookUserStoreLayout.instructionsDirectoryURL,
            instructionStoreExists: FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.instructionsDirectoryURL.path(percentEncoded: false)),
            targetsURL: SpellbookUserStoreLayout.targetsURL,
            targetsExists: FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.targetsURL.path(percentEncoded: false)),
            isInstalled: parseResult.hasManagedBlock,
            action: action,
            previewContent: nextContent
        )
    }

    static func apply(_ preview: InstructionPreview) throws {
        try apply(
            directoryURL: preview.targetInstructionURL.deletingLastPathComponent(),
            harnessFileNames: [preview.targetInstructionURL.lastPathComponent],
            installedSpells: []
        )
    }

    static func apply(directoryURL: URL, harnessFileNames: [String], installedSpells: [Spell] = []) throws {
        let harnesses = try harnesses(for: harnessFileNames)
        let spellsByRef = Dictionary(uniqueKeysWithValues: installedSpells.compactMap { spell -> (String, Spell)? in
            guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                return nil
            }
            return (TargetInstructionRef(uid: uid, version: spell.normalizedVersion).id, spell)
        })

        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.instructionsDirectoryURL, withIntermediateDirectories: true)

        for harness in harnesses {
            let targetInstructionURL = directoryURL.appending(path: harness.file)
            let existingContent = try? String(contentsOf: targetInstructionURL, encoding: .utf8)
            let migratedEntries = try legacyInstructionEntries(
                in: directoryURL,
                agent: harness.agent,
                spellsByRef: spellsByRef
            )
            let nextContent = try contentByApplyingManagedBlock(
                to: existingContent ?? "",
                entriesToMerge: migratedEntries
            )

            try nextContent.write(to: targetInstructionURL, atomically: true, encoding: .utf8)
        }

        try removeLegacyAgentContextPackage(in: directoryURL)
    }

    static func removeManagedBlocks(from directoryURL: URL, harnesses: [SpellbookHarness]) throws {
        for harness in harnesses {
            try removeManagedBlock(from: directoryURL.appending(path: harness.file))
        }
    }

    static func removeManagedBlock(from targetInstructionURL: URL) throws {
        guard FileManager.default.fileExists(atPath: targetInstructionURL.path(percentEncoded: false)) else {
            return
        }

        let existingContent = try String(contentsOf: targetInstructionURL, encoding: .utf8)
        let nextContent = try contentByRemovingManagedBlock(from: existingContent)

        if nextContent != existingContent {
            try nextContent.write(to: targetInstructionURL, atomically: true, encoding: .utf8)
        }
    }

    static func upsertInstruction(_ spell: Spell, in targetInstructionURL: URL) throws -> HarnessInstructionMutation {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw SpellbookError.message("Only uid-backed instructions can be added to a harness.")
        }

        let existingContent = try? String(contentsOf: targetInstructionURL, encoding: .utf8)
        let parseResult = parseManagedBlock(in: existingContent ?? "")
        try throwIfUnrepairableIssues(parseResult.issues)

        var entries = parseResult.entries
        let insertionIndex = entries.firstIndex { $0.uid == uid } ?? entries.count
        let existingVersions = entries.filter { $0.uid == uid }.map(\.version)
        entries.removeAll { $0.uid == uid }
        entries.insert(
            HarnessInstructionEntry(uid: uid, version: spell.normalizedVersion, raw: renderInstructionEntry(for: spell)),
            at: min(insertionIndex, entries.count)
        )

        let nextContent = try contentByReplacingManagedBlock(
            in: existingContent ?? "",
            with: managedBlock(entries: entries)
        )
        try nextContent.write(to: targetInstructionURL, atomically: true, encoding: .utf8)

        return HarnessInstructionMutation(
            inserted: existingVersions.isEmpty,
            replacedExistingVersion: !existingVersions.isEmpty && existingVersions != [spell.normalizedVersion]
        )
    }

    static func removeInstruction(uid: String, from targetInstructionURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: targetInstructionURL.path(percentEncoded: false)) else {
            return false
        }

        let existingContent = try String(contentsOf: targetInstructionURL, encoding: .utf8)
        let parseResult = parseManagedBlock(in: existingContent)
        try throwIfUnrepairableIssues(parseResult.issues)

        let entries = parseResult.entries.filter { $0.uid != uid }
        guard entries.count != parseResult.entries.count else {
            return false
        }

        let nextContent = try contentByReplacingManagedBlock(in: existingContent, with: managedBlock(entries: entries))
        try nextContent.write(to: targetInstructionURL, atomically: true, encoding: .utf8)
        return true
    }

    static func instructionRefs(in targetInstructionURL: URL) throws -> [TargetInstructionRef] {
        guard FileManager.default.fileExists(atPath: targetInstructionURL.path(percentEncoded: false)) else {
            return []
        }

        let content = try String(contentsOf: targetInstructionURL, encoding: .utf8)
        let parseResult = parseManagedBlock(in: content)
        return parseResult.entries.map(\.ref)
    }

    static func parseManagedBlock(in content: String) -> HarnessInstructionParseResult {
        guard let range = managedBlockRange(in: content) else {
            let hasPartialBlock = content.contains(startMarker) || content.contains(endMarker)
            return HarnessInstructionParseResult(
                hasManagedBlock: false,
                block: nil,
                entries: [],
                issues: hasPartialBlock
                    ? [HarnessInstructionIssue(type: "invalid_managed_block", message: "The harness file has an incomplete Spellbook managed block.", uid: nil, version: nil)]
                    : []
            )
        }

        let block = String(content[range])
        var entries: [HarnessInstructionEntry] = []
        var issues: [HarnessInstructionIssue] = []
        let lines = block.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let trimmedLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix(instructionStartPrefix) else {
                if trimmedLine == instructionEndMarker {
                    issues.append(HarnessInstructionIssue(
                        type: "malformed_instruction_entry",
                        message: "Spellbook instruction end marker appears without a start marker.",
                        uid: nil,
                        version: nil
                    ))
                }
                index += 1
                continue
            }

            let startIndex = index
            let attributes = markerAttributes(in: trimmedLine)
            let uid = attributes["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = attributes["version"].flatMap(Int.init)

            var endIndex: Int?
            index += 1
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate == instructionEndMarker {
                    endIndex = index
                    break
                }
                if candidate.hasPrefix(instructionStartPrefix) {
                    break
                }
                index += 1
            }

            guard let endIndex else {
                issues.append(HarnessInstructionIssue(
                    type: "malformed_instruction_entry",
                    message: "Spellbook instruction start marker does not have a matching end marker.",
                    uid: uid,
                    version: version
                ))
                continue
            }

            let raw = lines[startIndex...endIndex].joined(separator: "\n")
            if let uid, !uid.isEmpty, let version, version > 0 {
                entries.append(HarnessInstructionEntry(uid: uid, version: version, raw: raw))
            } else {
                issues.append(HarnessInstructionIssue(
                    type: "malformed_instruction_entry",
                    message: "Spellbook instruction marker must include uid and positive integer version attributes.",
                    uid: uid,
                    version: version
                ))
            }

            index = endIndex + 1
        }

        return HarnessInstructionParseResult(
            hasManagedBlock: true,
            block: block,
            entries: entries,
            issues: issues
        )
    }

    static func expectedManagedBlock(for refs: [TargetInstructionRef], spellsByRef: [String: Spell]) -> String? {
        var entries: [HarnessInstructionEntry] = []
        for ref in refs {
            guard let spell = spellsByRef[ref.id] else {
                return nil
            }
            entries.append(HarnessInstructionEntry(uid: ref.uid, version: ref.version, raw: renderInstructionEntry(for: spell)))
        }
        return managedBlock(entries: entries)
    }

    static func renderInstructionEntry(for spell: Spell) -> String {
        let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = spell.normalizedVersion
        let trigger = spell.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(instructionStartMarker(uid: uid, version: version))
        Trigger: \(trigger)
        File: \(SpellbookUserStoreLayout.harnessSpecPath(uid: uid, version: version))
        \(instructionEndMarker)
        """
    }

    private static func legacyInstructionEntries(
        in directoryURL: URL,
        agent: String,
        spellsByRef: [String: Spell]
    ) throws -> [HarnessInstructionEntry] {
        let refs = try legacyInstructionRefs(in: directoryURL, agent: agent)
        return refs.map { ref in
            HarnessInstructionEntry(
                uid: ref.uid,
                version: ref.version,
                raw: spellsByRef[ref.id].map(renderInstructionEntry)
            )
        }
    }

    private static func legacyInstructionRefs(in directoryURL: URL, agent: String) throws -> [TargetInstructionRef] {
        let legacyURLs = [
            AgentContextLayout.legacyRegistryURL(in: directoryURL, agent: agent),
            AgentContextLayout.packageURL(in: directoryURL).appending(path: "master.json"),
            AgentContextLayout.packageURL(in: directoryURL).appending(path: AgentContextLayout.legacyRegistryFileName),
            AgentContextLayout.packageURL(in: directoryURL).appending(path: "instruction-registry.json"),
            directoryURL.appending(path: "spells.json")
        ]

        for legacyURL in legacyURLs where FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) {
            let data = try Data(contentsOf: legacyURL)
            if let registry = try? JSONDecoder.spellbook.decode(TargetInstructionRegistry.self, from: data) {
                return registry.instructions
            }

            let legacyRegistry = try JSONDecoder.spellbook.decode(SpellRegistry.self, from: data)
            return legacyRegistry.spells.compactMap { spell -> TargetInstructionRef? in
                guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                    return nil
                }
                return TargetInstructionRef(uid: uid, version: spell.normalizedVersion)
            }
        }

        return []
    }

    private static func removeLegacyAgentContextPackage(in directoryURL: URL) throws {
        let packageURL = AgentContextLayout.packageURL(in: directoryURL)
        guard FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)) else {
            return
        }

        try FileManager.default.removeItem(at: packageURL)
    }

    private static func targetInstructionURL(from selectedURL: URL, preferredFileName: String) throws -> URL {
        if selectedURL.spellbookIsDirectory {
            let preferred = supportedFiles.contains(preferredFileName) ? preferredFileName : supportedFiles[0]
            return selectedURL.appending(path: preferred)
        }

        guard supportedFiles.contains(selectedURL.lastPathComponent) else {
            throw SpellbookError.message("Choose AGENTS.md, AGENT.md, CLAUDE.md, or a directory.")
        }

        return selectedURL
    }

    private static func contentByApplyingManagedBlock(
        to content: String,
        entriesToMerge incomingEntries: [HarnessInstructionEntry]
    ) throws -> String {
        let parseResult = parseManagedBlock(in: content)
        try throwIfUnrepairableIssues(parseResult.issues)

        var entries = parseResult.entries
        for incomingEntry in incomingEntries {
            guard !entries.contains(where: { $0.uid == incomingEntry.uid }) else {
                continue
            }
            entries.append(incomingEntry)
        }

        return try contentByReplacingManagedBlock(in: content, with: managedBlock(entries: entries))
    }

    private static func contentByReplacingManagedBlock(in content: String, with block: String) throws -> String {
        guard let range = managedBlockRange(in: content) else {
            if content.contains(startMarker) || content.contains(endMarker) {
                throw SpellbookError.message("The instruction file has an incomplete Spellbook block.")
            }

            let separator = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            return content + separator + block + "\n"
        }

        return content.replacingCharacters(in: range, with: block)
    }

    private static func contentByRemovingManagedBlock(from content: String) throws -> String {
        guard let range = managedBlockRange(in: content) else {
            if content.contains(startMarker) || content.contains(endMarker) {
                throw SpellbookError.message("The instruction file has an incomplete Spellbook block.")
            }

            return content
        }

        var nextContent = content.replacingCharacters(in: range, with: "")
        if nextContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextContent = ""
        }

        return nextContent
    }

    private static func managedBlockRange(in content: String) -> Range<String.Index>? {
        guard
            let start = content.range(of: startMarker),
            let end = content.range(of: endMarker),
            start.lowerBound < end.upperBound
        else {
            return nil
        }

        return start.lowerBound..<end.upperBound
    }

    private static func managedBlock(entries: [HarnessInstructionEntry]) -> String {
        var sections = [managedBlockHeader]
        sections.append(contentsOf: entries.map(renderEntry))
        sections.append(endMarker)
        return sections.joined(separator: "\n\n")
    }

    private static var managedBlockHeader: String {
        """
        \(startMarker)
        ## Spellbook Instructions

        The Spellbook app manages this block. Do not edit it by hand.

        For every task, check these Spellbook instruction triggers. When a trigger matches, read the linked `SPEC.md` and follow it. If a referenced file is missing or unreadable, report it in chat and continue without that Spellbook instruction.
        """
    }

    private static func renderEntry(_ entry: HarnessInstructionEntry) -> String {
        if let raw = entry.raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }

        return """
        \(instructionStartMarker(uid: entry.uid, version: entry.version))
        Trigger: when this Spellbook instruction applies.
        File: \(SpellbookUserStoreLayout.harnessSpecPath(uid: entry.uid, version: entry.version))
        \(instructionEndMarker)
        """
    }

    private static func instructionStartMarker(uid: String, version: Int) -> String {
        #"<!-- spellbook:instruction:start uid="\#(escapedAttribute(uid))" version="\#(max(version, 1))" -->"#
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func markerAttributes(in marker: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: attributePattern) else {
            return [:]
        }

        let range = NSRange(marker.startIndex..<marker.endIndex, in: marker)
        let matches = regex.matches(in: marker, range: range)
        var attributes: [String: String] = [:]
        for match in matches {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: marker),
                  let valueRange = Range(match.range(at: 2), in: marker)
            else {
                continue
            }

            attributes[String(marker[keyRange])] = unescapedAttribute(String(marker[valueRange]))
        }
        return attributes
    }

    private static func unescapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func throwIfUnrepairableIssues(_ issues: [HarnessInstructionIssue]) throws {
        guard issues.isEmpty else {
            throw SpellbookError.message("The Spellbook managed block has malformed instruction markers. Repair the target before changing installed instructions.")
        }
    }
}

struct InstructionPreview: Equatable {
    var targetInstructionURL: URL
    var targetExists: Bool
    var agent: String
    var managedInstructionCount: Int
    var instructionStoreURL: URL
    var instructionStoreExists: Bool
    var targetsURL: URL
    var targetsExists: Bool
    var isInstalled: Bool
    var action: ManagedBlockAction
    var previewContent: String
}

enum ManagedBlockAction: String {
    case add = "Add managed block"
    case update = "Update managed block"
}
