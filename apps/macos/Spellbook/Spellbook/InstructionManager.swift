import Darwin
import Foundation

enum AgentContextLayout {
    static let packageDirectoryName = ".agent-context"
    static let manifestFileName = "manifest.json"
    static let instructionsDirectoryName = "instructions"
    static let legacyRegistryFileName = "registry.json"

    static func packageURL(in directoryURL: URL) -> URL {
        directoryURL.appending(path: packageDirectoryName, directoryHint: .isDirectory)
    }

    static func manifestURL(in directoryURL: URL) -> URL {
        packageURL(in: directoryURL).appending(path: manifestFileName)
    }

    static func registryFileName(for agent: String) -> String {
        "\(agent).registry.json"
    }

    static func registryURL(in directoryURL: URL, agent: String) -> URL {
        packageURL(in: directoryURL).appending(path: registryFileName(for: agent))
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
        let agent = agentName(for: fileName)
        return SpellbookHarness(agent: agent, file: fileName, registry: registryFileName(for: agent))
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
    static let binDirectoryName = "bin"
    static let registryFileName = "registry.json"
    static let legacyLibraryFileName = "library.json"
    static let targetsFileName = "targets.json"
    static let errorsFileName = "errors.json"
    static let specFileName = "SPEC.md"
    static let resolverFileName = "spellbook-agent-context"

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

    static var systemRegistryURL: URL {
        registryDirectoryURL.appending(path: registryFileName)
    }

    static var legacyLibraryURL: URL {
        registryDirectoryURL.appending(path: legacyLibraryFileName)
    }

    static var targetsURL: URL {
        registryDirectoryURL.appending(path: targetsFileName)
    }

    static var errorsURL: URL {
        registryDirectoryURL.appending(path: errorsFileName)
    }

    static var instructionsDirectoryURL: URL {
        rootURL.appending(path: instructionsDirectoryName, directoryHint: .isDirectory)
    }

    static var legacySpellsDirectoryURL: URL {
        rootURL.appending(path: legacySpellsDirectoryName, directoryHint: .isDirectory)
    }

    static var binDirectoryURL: URL {
        rootURL.appending(path: binDirectoryName, directoryHint: .isDirectory)
    }

    static var resolverURL: URL {
        binDirectoryURL.appending(path: resolverFileName)
    }

    static func instructionDirectoryURL(uid: String, version: Int) -> URL {
        instructionsDirectoryURL
            .appending(path: safeStoragePathComponent(uid), directoryHint: .isDirectory)
            .appending(path: "\(max(version, 1))", directoryHint: .isDirectory)
    }

    static func specURL(uid: String, version: Int) -> URL {
        instructionDirectoryURL(uid: uid, version: version).appending(path: specFileName)
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

struct AgentContextManifest: Codable, Equatable {
    var schemaVersion: Int
    var name: String
    var type: String
    var version: String
    var entrypoints: AgentContextEntrypoints
    var paths: AgentContextPaths
    var resolver: AgentContextResolver
    var loader: AgentContextLoader

    static func standard(harnesses: [SpellbookHarness]) -> AgentContextManifest {
        AgentContextManifest(
            schemaVersion: 1,
            name: "spellbook-agent-context",
            type: "agent-context-package",
            version: "0.1.0",
            entrypoints: .standard(harnesses: harnesses),
            paths: .standard,
            resolver: .standard,
            loader: .standard
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case type
        case version
        case entrypoints
        case paths
        case resolver
        case loader
    }
}

struct AgentContextEntrypoints: Codable, Equatable {
    var instructionRegistries: [String: String]
    var installedRegistry: String
    var knownTargets: String
    var diagnostics: String

    static func standard(harnesses: [SpellbookHarness]) -> AgentContextEntrypoints {
        AgentContextEntrypoints(
            instructionRegistries: Dictionary(uniqueKeysWithValues: harnesses.map { ($0.agent, $0.registry) }),
            installedRegistry: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/\(SpellbookUserStoreLayout.registryFileName)",
            knownTargets: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/\(SpellbookUserStoreLayout.targetsFileName)",
            diagnostics: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/\(SpellbookUserStoreLayout.errorsFileName)"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case instructionRegistries = "instruction_registries"
        case installedRegistry = "installed_registry"
        case knownTargets = "known_targets"
        case diagnostics
    }
}

struct AgentContextPaths: Codable, Equatable {
    var targetPackage: String
    var systemRegistry: String
    var instructionStore: String

    static let standard = AgentContextPaths(
        targetPackage: "\(AgentContextLayout.packageDirectoryName)/",
        systemRegistry: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.registryDirectoryName)/",
        instructionStore: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.instructionsDirectoryName)/"
    )

    private enum CodingKeys: String, CodingKey {
        case targetPackage = "target_package"
        case systemRegistry = "system_registry"
        case instructionStore = "instruction_store"
    }
}

struct AgentContextResolver: Codable, Equatable {
    var command: String

    static let standard = AgentContextResolver(
        command: "~/\(SpellbookUserStoreLayout.rootDirectoryName)/\(SpellbookUserStoreLayout.binDirectoryName)/\(SpellbookUserStoreLayout.resolverFileName)"
    )
}

struct AgentContextLoader: Codable, Equatable {
    var activation: String
    var readOrder: [String]

    static let standard = AgentContextLoader(
        activation: "trigger_match",
        readOrder: [
            "resolver_list_triggers",
            "resolver_read_matching_specs"
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
    private static let harnessRootTag = "HARNESS_ROOT"
    private static let agentTag = "AGENT_NAME"

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

        var seenAgents: Set<String> = []
        return normalizedFiles.compactMap { fileName in
            let harness = AgentContextLayout.harness(for: fileName)
            guard !seenAgents.contains(harness.agent) else {
                return nil
            }
            seenAgents.insert(harness.agent)
            return harness
        }
    }

    static func preview(selectedURL: URL?, preferredFileName: String) throws -> InstructionPreview {
        guard let selectedURL else {
            throw SpellbookError.message("Choose a directory or instruction file first.")
        }

        let target = try targetInstructionURL(from: selectedURL, preferredFileName: preferredFileName)
        let directory = target.deletingLastPathComponent()
        let harness = AgentContextLayout.harness(for: target.lastPathComponent)
        let packageURL = AgentContextLayout.packageURL(in: directory)
        let manifestURL = AgentContextLayout.manifestURL(in: directory)
        let registryURL = AgentContextLayout.registryURL(in: directory, agent: harness.agent)
        let existingContent = try? String(contentsOf: target, encoding: .utf8)
        let targetExists = existingContent != nil
        let isInstalled = existingContent?.contains(startMarker) == true
        let nextContent = try contentByApplyingManagedBlock(to: existingContent ?? "", targetInstructionURL: target, agent: harness.agent)
        let action: ManagedBlockAction = isInstalled ? .update : .add

        return InstructionPreview(
            targetInstructionURL: target,
            targetExists: targetExists,
            agent: harness.agent,
            packageURL: packageURL,
            manifestURL: manifestURL,
            manifestExists: FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)),
            registryURL: registryURL,
            registryExists: FileManager.default.fileExists(atPath: registryURL.path(percentEncoded: false)),
            systemRegistryURL: SpellbookUserStoreLayout.systemRegistryURL,
            systemRegistryExists: FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.systemRegistryURL.path(percentEncoded: false)),
            targetsURL: SpellbookUserStoreLayout.targetsURL,
            targetsExists: FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.targetsURL.path(percentEncoded: false)),
            errorsURL: SpellbookUserStoreLayout.errorsURL,
            errorsExists: FileManager.default.fileExists(atPath: SpellbookUserStoreLayout.errorsURL.path(percentEncoded: false)),
            resolverURL: SpellbookUserStoreLayout.resolverURL,
            resolverExists: FileManager.default.isExecutableFile(atPath: SpellbookUserStoreLayout.resolverURL.path(percentEncoded: false)),
            isInstalled: isInstalled,
            action: action,
            previewContent: nextContent
        )
    }

    static func apply(_ preview: InstructionPreview) throws {
        try apply(directoryURL: preview.targetInstructionURL.deletingLastPathComponent(), harnessFileNames: [preview.targetInstructionURL.lastPathComponent])
    }

    static func apply(directoryURL: URL, harnessFileNames: [String]) throws {
        let harnesses = try harnesses(for: harnessFileNames)
        let packageURL = AgentContextLayout.packageURL(in: directoryURL)

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.registryDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.instructionsDirectoryURL, withIntermediateDirectories: true)
        try installResolver()

        for harness in harnesses {
            let targetInstructionURL = directoryURL.appending(path: harness.file)
            let existingContent = try? String(contentsOf: targetInstructionURL, encoding: .utf8)
            let nextContent = try contentByApplyingManagedBlock(to: existingContent ?? "", targetInstructionURL: targetInstructionURL, agent: harness.agent)
            let registryURL = AgentContextLayout.registryURL(in: directoryURL, agent: harness.agent)

            try migrateLegacyTargetRegistryIfNeeded(in: directoryURL, to: registryURL, agent: harness.agent)
            if !FileManager.default.fileExists(atPath: registryURL.path(percentEncoded: false)) {
                let data = try JSONEncoder.spellbook.encode(TargetInstructionRegistry.empty(agent: harness.agent))
                try data.write(to: registryURL, options: [.atomic])
            }

            try nextContent.write(to: targetInstructionURL, atomically: true, encoding: .utf8)
        }

        let manifestData = try JSONEncoder.spellbook.encode(AgentContextManifest.standard(harnesses: harnesses))
        try manifestData.write(to: AgentContextLayout.manifestURL(in: directoryURL), options: [.atomic])
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

    static func installResolver() throws {
        try FileManager.default.createDirectory(at: SpellbookUserStoreLayout.binDirectoryURL, withIntermediateDirectories: true)
        let resolverURL = SpellbookUserStoreLayout.resolverURL
        let sourceURL = try bundledResolverURL()
        try ensureResolverTargetIsUsable(sourceURL)

        if try resolverSymlink(at: resolverURL, pointsTo: sourceURL) {
            return
        }

        if FileManager.default.fileExists(atPath: resolverURL.path(percentEncoded: false)) || isSymlink(resolverURL) {
            try FileManager.default.removeItem(at: resolverURL)
        }

        try FileManager.default.createSymbolicLink(
            at: resolverURL,
            withDestinationURL: sourceURL.standardizedFileURL
        )
    }

    private static func bundledResolverURL() throws -> URL {
        let resolverFileName = SpellbookUserStoreLayout.resolverFileName
        let candidates: [URL?] = [
            Bundle.main.url(forAuxiliaryExecutable: resolverFileName),
            Bundle.main.url(forResource: resolverFileName, withExtension: nil),
            Bundle.main.bundleURL.appending(path: resolverFileName),
            Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(resolverFileName)"),
            Bundle.main.bundleURL.appending(path: "Contents/Resources/\(resolverFileName)"),
            Bundle.main.bundleURL.deletingLastPathComponent().appending(path: resolverFileName)
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }

        throw SpellbookError.message("The bundled Spellbook resolver is missing. Rebuild or reinstall Raddus Spellbook.")
    }

    private static func ensureResolverTargetIsUsable(_ url: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) else {
            throw SpellbookError.message("The bundled Spellbook resolver is not executable. Rebuild or reinstall Raddus Spellbook.")
        }
    }

    private static func resolverSymlink(at resolverURL: URL, pointsTo sourceURL: URL) throws -> Bool {
        guard isSymlink(resolverURL) else {
            return false
        }

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: resolverURL.path(percentEncoded: false))
        let destinationURL = URL(fileURLWithPath: destination, relativeTo: resolverURL.deletingLastPathComponent())
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        return destinationURL.path(percentEncoded: false) == source.path(percentEncoded: false)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) != nil
    }

    private static func migrateLegacyTargetRegistryIfNeeded(in directoryURL: URL, to nextURL: URL, agent: String) throws {
        guard !FileManager.default.fileExists(atPath: nextURL.path(percentEncoded: false)) else {
            return
        }

        let legacyURLs = [
            AgentContextLayout.packageURL(in: directoryURL).appending(path: "master.json"),
            AgentContextLayout.packageURL(in: directoryURL).appending(path: AgentContextLayout.legacyRegistryFileName),
            AgentContextLayout.packageURL(in: directoryURL).appending(path: "instruction-registry.json"),
            directoryURL.appending(path: "spells.json")
        ]

        for legacyURL in legacyURLs where FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)) {
            let data = try Data(contentsOf: legacyURL)
            let legacyRegistry = try JSONDecoder.spellbook.decode(SpellRegistry.self, from: data)
            let refs = legacyRegistry.spells.compactMap { spell -> TargetInstructionRef? in
                guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                    return nil
                }
                return TargetInstructionRef(uid: uid, version: spell.normalizedVersion)
            }

            let registry = TargetInstructionRegistry(schemaVersion: 1, agent: agent, instructions: refs)
            let nextData = try JSONEncoder.spellbook.encode(registry)
            try FileManager.default.createDirectory(at: nextURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try nextData.write(to: nextURL, options: [.atomic])
            return
        }
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

    private static func contentByApplyingManagedBlock(to content: String, targetInstructionURL: URL, agent: String) throws -> String {
        let block = managedBlock(targetInstructionURL: targetInstructionURL, agent: agent)
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

    private static func managedBlock(targetInstructionURL: URL, agent: String) -> String {
        let harnessRoot = targetInstructionURL.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        return managedBlockTemplate
            .replacingOccurrences(of: fileTargetTag, with: targetInstructionURL.standardizedFileURL.path(percentEncoded: false))
            .replacingOccurrences(of: harnessRootTag, with: harnessRoot)
            .replacingOccurrences(of: agentTag, with: agent)
    }

    private static var managedBlockTemplate: String {
        """
        \(startMarker)
        ## Agent Context Package

        Selected instruction file target: FILE_TARGET
        Selected harness root: HARNESS_ROOT
        Selected agent key: AGENT_NAME

        For every task, load Spellbook instructions through the local resolver only:

        1. Run `~/.spellbook/bin/spellbook-agent-context list-triggers --target <cwd> --harness-root "HARNESS_ROOT" --agent AGENT_NAME`.
           If the current working directory is not inside the intended target, pass `FILE_TARGET` as `--target`.

        2. If the resolver command is missing, exits before returning usable JSON, or returns malformed JSON, report that in chat and continue without Spellbook-loaded instructions.

        3. Report any resolver diagnostics in chat. Missing pinned instruction versions are soft-skipped for this run.

        4. Inspect the returned instruction triggers, names, descriptions, versions, and tags. For each matching instruction, run `~/.spellbook/bin/spellbook-agent-context read-spec --target <cwd> --harness-root "HARNESS_ROOT" --agent AGENT_NAME --uid <uid> --version <version>` and apply the returned content.

        5. Suggest useful future instructions in chat only. Do not write suggestion, staging, archive, registry, diagnostic, or SPEC files.

        Do not read Spellbook registry files or SPEC files directly as a fallback. The macOS Spellbook app is the only writer of durable Spellbook state.
        \(endMarker)
        """
    }

}

struct InstructionPreview: Equatable {
    var targetInstructionURL: URL
    var targetExists: Bool
    var agent: String
    var packageURL: URL
    var manifestURL: URL
    var manifestExists: Bool
    var registryURL: URL
    var registryExists: Bool
    var systemRegistryURL: URL
    var systemRegistryExists: Bool
    var targetsURL: URL
    var targetsExists: Bool
    var errorsURL: URL
    var errorsExists: Bool
    var resolverURL: URL
    var resolverExists: Bool
    var isInstalled: Bool
    var action: ManagedBlockAction
    var previewContent: String
}

enum ManagedBlockAction: String {
    case add = "Add managed block"
    case update = "Update managed block"
}
