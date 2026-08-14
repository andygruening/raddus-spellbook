import Foundation

enum AgentContextLayout {
    static let packageDirectoryName = ".agent-context"
    static let manifestFileName = "manifest.json"
    static let registryDirectoryName = "registry"
    static let registryFileName = "master.json"
    static let legacyRegistryFileName = "registry.json"
    static let stagingFileName = "staging.json"
    static let archiveFileName = "archive.json"
    static let instructionsDirectoryName = "instructions"

    static func packageURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: packageDirectoryName, directoryHint: .isDirectory)
    }

    static func manifestURL(in directoryURL: URL) -> URL {
        packageURL(in: directoryURL).appending(path: manifestFileName)
    }

    static func registryURL(in directoryURL: URL) -> URL {
        packageURL(in: directoryURL).appending(path: registryFileName)
    }

    static func stagingURL(in directoryURL: URL) -> URL {
        registryDirectoryURL(in: directoryURL).appending(path: stagingFileName)
    }

    static func archiveURL(in directoryURL: URL) -> URL {
        registryDirectoryURL(in: directoryURL).appending(path: archiveFileName)
    }

    static func registryDirectoryURL(in directoryURL: URL) -> URL {
        packageURL(in: directoryURL).appending(path: registryDirectoryName, directoryHint: .isDirectory)
    }

    static func instructionsDirectoryURL(in directoryURL: URL) -> URL {
        packageURL(in: directoryURL).appending(path: instructionsDirectoryName, directoryHint: .isDirectory)
    }

    static func canonicalInstructionFilePath(_ file: String) -> String {
        let trimmedFile = file.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFile.hasPrefix("spells/") {
            return "\(instructionsDirectoryName)/\(trimmedFile.dropFirst("spells/".count))"
        }
        return trimmedFile
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
}

enum SpellbookUserStoreLayout {
    static let rootDirectoryName = ".spellbook"
    static let registryDirectoryName = "registry"
    static let spellsDirectoryName = "spells"
    static let libraryFileName = "library.json"
    static let stagingFileName = "staging.json"
    static let archiveFileName = "archive.json"
    static let specFileName = "SPEC.md"

    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: rootDirectoryName, directoryHint: .isDirectory)
    }

    static var registryDirectoryURL: URL {
        rootURL.appending(path: registryDirectoryName, directoryHint: .isDirectory)
    }

    static var libraryURL: URL {
        registryDirectoryURL.appending(path: libraryFileName)
    }

    static var spellsDirectoryURL: URL {
        rootURL.appending(path: spellsDirectoryName, directoryHint: .isDirectory)
    }

    static var stagingURL: URL {
        registryDirectoryURL.appending(path: stagingFileName)
    }

    static var archiveURL: URL {
        registryDirectoryURL.appending(path: archiveFileName)
    }

    static func spellDirectoryURL(storageID: String, version: Int) -> URL {
        spellsDirectoryURL
            .appending(path: safeStoragePathComponent(storageID), directoryHint: .isDirectory)
            .appending(path: "\(max(version, 1))", directoryHint: .isDirectory)
    }

    static func specURL(storageID: String, version: Int) -> URL {
        spellDirectoryURL(storageID: storageID, version: version).appending(path: specFileName)
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

        return collapsed.isEmpty ? "spell" : collapsed
    }
}

struct AgentContextManifest: Codable, Equatable {
    var schemaVersion: Int
    var name: String
    var type: String
    var version: String
    var entrypoints: AgentContextEntrypoints
    var paths: AgentContextPaths
    var loader: AgentContextLoader

    static let standard = AgentContextManifest(
        schemaVersion: 1,
        name: "spellbook-agent-context",
        type: "agent-context-package",
        version: "0.1.0",
        entrypoints: .standard,
        paths: .standard,
        loader: .standard
    )

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case type
        case version
        case entrypoints
        case paths
        case loader
    }
}

struct AgentContextEntrypoints: Codable, Equatable {
    var instructionRegistry: String
    var installedLibrary: String?
    var stagedInstructions: String
    var archivedInstructions: String

    static let standard = AgentContextEntrypoints(
        instructionRegistry: AgentContextLayout.registryFileName,
        installedLibrary: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/\(SpellbookUserStoreLayout.libraryFileName)",
        stagedInstructions: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/\(SpellbookUserStoreLayout.stagingFileName)",
        archivedInstructions: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/\(SpellbookUserStoreLayout.archiveFileName)"
    )

    private enum CodingKeys: String, CodingKey {
        case instructionRegistry = "instruction_registry"
        case installedLibrary = "installed_library"
        case stagedInstructions = "staged_instructions"
        case archivedInstructions = "archived_instructions"
    }
}

struct AgentContextPaths: Codable, Equatable {
    var repoRegistry: String
    var globalRegistry: String
    var spellStore: String

    static let standard = AgentContextPaths(
        repoRegistry: AgentContextLayout.registryFileName,
        globalRegistry: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/",
        spellStore: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.spellsDirectoryName)/"
    )

    private enum CodingKeys: String, CodingKey {
        case repoRegistry = "repo_registry"
        case globalRegistry = "global_registry"
        case spellStore = "spell_store"
    }
}

struct AgentContextLoader: Codable, Equatable {
    var activation: String
    var readOrder: [String]

    static let standard = AgentContextLoader(
        activation: "trigger_match",
        readOrder: [
            "manifest",
            "instruction_registry",
            "matching_spell_specs"
        ]
    )

    private enum CodingKeys: String, CodingKey {
        case activation
        case readOrder = "read_order"
    }
}

enum InstructionManager {
    static let supportedFiles = ["AGENTS.md", "AGENT.md", "CLAUDE.md"]
    static let startMarker = "<!-- spellbook:start -->"
    static let endMarker = "<!-- spellbook:end -->"
    private static let fileTargetTag = "FILE_TARGET"

    static func preview(selectedURL: URL?, preferredFileName: String) throws -> InstructionPreview {
        guard let selectedURL else {
            throw SpellbookError.message("Choose a directory or instruction file first.")
        }

        let target = try targetInstructionURL(from: selectedURL, preferredFileName: preferredFileName)
        let directory = target.deletingLastPathComponent()
        let packageURL = AgentContextLayout.packageURL(in: directory)
        let manifestURL = AgentContextLayout.manifestURL(in: directory)
        let registryURL = AgentContextLayout.registryURL(in: directory)
        let stagingURL = SpellbookUserStoreLayout.stagingURL
        let archiveURL = SpellbookUserStoreLayout.archiveURL
        let existingContent = try? String(contentsOf: target, encoding: .utf8)
        let targetExists = existingContent != nil
        let isInstalled = existingContent?.contains(startMarker) == true
        let nextContent = try contentByApplyingManagedBlock(to: existingContent ?? "", targetInstructionURL: target)
        let action: ManagedBlockAction = isInstalled ? .update : .add

        return InstructionPreview(
            targetInstructionURL: target,
            targetExists: targetExists,
            isInstalled: isInstalled,
            packageURL: packageURL,
            manifestURL: manifestURL,
            manifestExists: FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)),
            registryURL: registryURL,
            registryExists: FileManager.default.fileExists(atPath: registryURL.path(percentEncoded: false)),
            stagingURL: stagingURL,
            stagingExists: FileManager.default.fileExists(atPath: stagingURL.path(percentEncoded: false)),
            archiveURL: archiveURL,
            archiveExists: FileManager.default.fileExists(atPath: archiveURL.path(percentEncoded: false)),
            action: action,
            previewContent: nextContent
        )
    }

    static func apply(_ preview: InstructionPreview) throws {
        let existingContent = try? String(contentsOf: preview.targetInstructionURL, encoding: .utf8)
        let nextContent = try contentByApplyingManagedBlock(to: existingContent ?? "", targetInstructionURL: preview.targetInstructionURL)

        let targetDirectory = preview.targetInstructionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: preview.packageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.spellsDirectoryURL, withIntermediateDirectories: true)
        try migrateLegacyInstructionsDirectory(in: targetDirectory, packageURL: preview.packageURL)
        try migrateLegacyRegistryIfNeeded(
            from: targetDirectory.appending(path: "spells.json"),
            to: preview.registryURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: preview.packageURL.appending(path: "instruction-registry.json"),
            to: preview.registryURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: preview.packageURL.appending(path: AgentContextLayout.legacyRegistryFileName),
            to: preview.registryURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: AgentContextLayout.registryDirectoryURL(in: targetDirectory).appending(path: "master.json"),
            to: preview.registryURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: targetDirectory.appending(path: "spells-staging.json"),
            to: preview.stagingURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: preview.packageURL.appending(path: "instruction-staging.json"),
            to: preview.stagingURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: AgentContextLayout.stagingURL(in: targetDirectory),
            to: preview.stagingURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: targetDirectory.appending(path: "spells-archive.json"),
            to: preview.archiveURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: preview.packageURL.appending(path: "instruction-archive.json"),
            to: preview.archiveURL
        )
        try migrateLegacyRegistryIfNeeded(
            from: AgentContextLayout.archiveURL(in: targetDirectory),
            to: preview.archiveURL
        )

        let manifestData = try JSONEncoder.spellbook.encode(AgentContextManifest.standard)
        try manifestData.write(to: preview.manifestURL, options: [.atomic])

        if !FileManager.default.fileExists(atPath: preview.registryURL.path(percentEncoded: false)) {
            let registry = SpellRegistry(
                version: 1,
                agent: AgentContextLayout.agentName(for: preview.targetInstructionURL.lastPathComponent),
                spells: []
            )
            let data = try JSONEncoder.spellbook.encode(registry)
            try data.write(to: preview.registryURL, options: [.atomic])
        }

        if !FileManager.default.fileExists(atPath: preview.stagingURL.path(percentEncoded: false)) {
            let data = try JSONEncoder.spellbook.encode(SpellRegistry.empty)
            try data.write(to: preview.stagingURL, options: [.atomic])
        }

        if !FileManager.default.fileExists(atPath: preview.archiveURL.path(percentEncoded: false)) {
            let data = try JSONEncoder.spellbook.encode(SpellRegistry.empty)
            try data.write(to: preview.archiveURL, options: [.atomic])
        }

        try nextContent.write(to: preview.targetInstructionURL, atomically: true, encoding: .utf8)
    }

    private static func migrateLegacyRegistryIfNeeded(from legacyURL: URL, to nextURL: URL) throws {
        guard FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)),
              !FileManager.default.fileExists(atPath: nextURL.path(percentEncoded: false)) else {
            return
        }

        let data = try Data(contentsOf: legacyURL)
        var registry = try JSONDecoder.spellbook.decode(SpellRegistry.self, from: data)
        registry.spells = try registry.spells.map { spell in
            try migratedSpellReference(spell, sourceRegistryURL: legacyURL)
        }
        let nextData = try JSONEncoder.spellbook.encode(registry)
        try FileManager.default.createDirectory(at: nextURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try nextData.write(to: nextURL, options: [.atomic])
        try FileManager.default.removeItem(at: legacyURL)
    }

    private static func migratedSpellReference(_ spell: Spell, sourceRegistryURL: URL) throws -> Spell {
        var migrated = spell
        if migrated.uid == nil && migrated.localID == nil {
            migrated.localID = "local-\(UUID().uuidString)"
        }
        migrated.version = migrated.normalizedVersion

        let content = migrated.content ?? legacyMarkdownContent(for: migrated, registryURL: sourceRegistryURL)
        if let content {
            let specURL = SpellbookUserStoreLayout.specURL(storageID: migrated.storageID, version: migrated.normalizedVersion)
            try FileManager.default.createDirectory(at: specURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: specURL, atomically: true, encoding: .utf8)
            if migrated.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                migrated.trigger = Spell.trigger(from: content) ?? ""
            }
        }

        return migrated
    }

    private static func legacyMarkdownContent(for spell: Spell, registryURL: URL) -> String? {
        guard let markdownURL = try? legacyMarkdownURL(for: spell, registryURL: registryURL),
              FileManager.default.fileExists(atPath: markdownURL.path(percentEncoded: false)) else {
            return nil
        }

        return try? String(contentsOf: markdownURL, encoding: .utf8)
    }

    private static func legacyMarkdownURL(for spell: Spell, registryURL: URL) throws -> URL {
        let trimmedFile = AgentContextLayout.canonicalInstructionFilePath(spell.file)
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

    private static func agentContextPackageURL(for registryURL: URL) -> URL {
        let parentURL = registryURL.deletingLastPathComponent()
        if parentURL.lastPathComponent == AgentContextLayout.registryDirectoryName {
            return parentURL.deletingLastPathComponent()
        }
        return parentURL
    }

    private static func migrateLegacyInstructionsDirectory(in targetDirectory: URL, packageURL: URL) throws {
        let legacyURL = targetDirectory.appending(path: "spells", directoryHint: .isDirectory)
        let nextURL = packageURL.appending(path: AgentContextLayout.instructionsDirectoryName, directoryHint: .isDirectory)

        guard FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) else {
            try FileManager.default.createDirectory(at: nextURL, withIntermediateDirectories: true)
            return
        }

        if !FileManager.default.fileExists(atPath: nextURL.path(percentEncoded: false)) {
            try FileManager.default.moveItem(at: legacyURL, to: nextURL)
            return
        }

        let legacyItems = try FileManager.default.contentsOfDirectory(
            at: legacyURL,
            includingPropertiesForKeys: nil
        )
        for legacyItem in legacyItems {
            let destination = nextURL.appending(path: legacyItem.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.moveItem(at: legacyItem, to: destination)
            }
        }

        if try FileManager.default.contentsOfDirectory(atPath: legacyURL.path(percentEncoded: false)).isEmpty {
            try FileManager.default.removeItem(at: legacyURL)
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

    private static func targetInstructionURL(from selectedURL: URL, preferredFileName: String) throws -> URL {
        if selectedURL.spellbookIsDirectory {
            for fileName in supportedFiles {
                let candidate = selectedURL.appending(path: fileName)
                if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                    return candidate
                }
            }

            let preferred = supportedFiles.contains(preferredFileName) ? preferredFileName : supportedFiles[0]
            return selectedURL.appending(path: preferred)
        }

        guard supportedFiles.contains(selectedURL.lastPathComponent) else {
            throw SpellbookError.message("Choose AGENTS.md, AGENT.md, CLAUDE.md, or a directory.")
        }

        return selectedURL
    }

    private static func contentByApplyingManagedBlock(to content: String, targetInstructionURL: URL) throws -> String {
        let block = managedBlock(targetInstructionURL: targetInstructionURL)
        guard
            let start = content.range(of: startMarker),
            let end = content.range(of: endMarker)
        else {
            if content.contains(startMarker) || content.contains(endMarker) {
                throw SpellbookError.message("The instruction file has an incomplete Spellbook block.")
            }

            let separator = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            return content + separator + block + "\n"
        }

        guard start.lowerBound < end.upperBound else {
            throw SpellbookError.message("The instruction file has an invalid Spellbook block.")
        }

        return content.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
    }

    private static func contentByRemovingManagedBlock(from content: String) throws -> String {
        guard
            let start = content.range(of: startMarker),
            let end = content.range(of: endMarker)
        else {
            if content.contains(startMarker) || content.contains(endMarker) {
                throw SpellbookError.message("The instruction file has an incomplete Spellbook block.")
            }

            return content
        }

        guard start.lowerBound < end.upperBound else {
            throw SpellbookError.message("The instruction file has an invalid Spellbook block.")
        }

        var nextContent = content.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
        if nextContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextContent = ""
        }

        return nextContent
    }

    private static func managedBlock(targetInstructionURL: URL) -> String {
        managedBlockTemplate.replacingOccurrences(
            of: fileTargetTag,
            with: targetInstructionURL.standardizedFileURL.path(percentEncoded: false)
        )
    }

    private static var managedBlockTemplate: String {
        """
        \(startMarker)
        ## Agent Context Package

        Selected instruction file target: FILE_TARGET

        For every task, use the agent context package in two ways:

        1. Query installed instructions before and during the work.
           Treat the selected target directory's .agent-context/manifest.json as the package entrypoint. Resolve the selected target directory as the directory that contains FILE_TARGET, not relative to the project root or current working directory.

           Read the manifest first, then read the instruction registry named by entrypoints.instruction_registry, normally .agent-context/master.json. Inspect each instruction's trigger first, then its name, description, version, and tags if more context is needed, to decide whether it should activate for the current task. Do not eagerly read every spell body. When an instruction's trigger matches the current task, read ~/.spellbook/spells/<uid-or-localID>/<version>/SPEC.md and apply that instruction.

           Suggested entries are review-only. Do not read or activate ~/.spellbook/registry/staging.json during task execution.

        2. Track new reusable instructions while working.
           When you identify a durable instruction, workflow convention, project setup requirement, review rule, or reusable feedback pattern, write a suggestion index entry to ~/.spellbook/registry/staging.json, and write the full markdown instructions to ~/.spellbook/spells/<localID>/1/SPEC.md. Capture broadly useful instructions, not only review guidance; for example, a preference that web apps should be set up so they are deployable to Cloudflare is a valid instruction.

           During capture, do not modify .agent-context/master.json and do not overwrite existing spell versions unless explicitly asked.

        Keep .agent-context/manifest.json, .agent-context/master.json, ~/.spellbook/registry/library.json, ~/.spellbook/registry/staging.json, and ~/.spellbook/registry/archive.json valid JSON.

        Example manifest:

        ```json
        {
          "schema_version": 1,
          "name": "spellbook-agent-context",
          "type": "agent-context-package",
          "version": "0.1.0",
          "entrypoints": {
            "instruction_registry": "master.json",
            "installed_library": "~/.spellbook/registry/library.json",
            "staged_instructions": "~/.spellbook/registry/staging.json",
            "archived_instructions": "~/.spellbook/registry/archive.json"
          },
          "paths": {
            "repo_registry": "master.json",
            "global_registry": "~/.spellbook/registry/",
            "spell_store": "~/.spellbook/spells/"
          },
          "loader": {
            "activation": "trigger_match",
            "read_order": ["manifest", "instruction_registry", "matching_spell_specs"]
          }
        }
        ```

        Example instruction registry:

        ```json
        {
          "version": 1,
          "instructions": [
            {
              "name": "Cloudflare-deployable web apps",
              "description": "Set up web apps so they can be deployed to Cloudflare.",
              "trigger": "Use when building or restructuring a web app, site, dashboard, or frontend tool that should be deployable.",
              "tags": ["deployment", "cloudflare", "web"],
              "uid": "spell-uid",
              "version": 3
            }
          ]
        }
        ```

        Each installed instruction entry should include uid or localID, name, description, trigger, tags, and version. The trigger must describe when the agent should activate the instruction. Keep the full durable instruction, trigger, safe path, and any supporting details in the versioned SPEC.md file.

        Update existing matching instructions instead of duplicating them. Do not include secrets, private customer data, or one-off observations.
        \(endMarker)
        """
    }
}

struct InstructionPreview: Equatable {
    var targetInstructionURL: URL
    var targetExists: Bool
    var isInstalled: Bool
    var packageURL: URL
    var manifestURL: URL
    var manifestExists: Bool
    var registryURL: URL
    var registryExists: Bool
    var stagingURL: URL
    var stagingExists: Bool
    var archiveURL: URL
    var archiveExists: Bool
    var action: ManagedBlockAction
    var previewContent: String
}

enum ManagedBlockAction: String {
    case add = "Add managed block"
    case update = "Update managed block"
}
