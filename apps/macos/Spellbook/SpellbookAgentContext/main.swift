import Darwin
import Foundation

private enum ResolverExit: Int32 {
    case success = 0
    case operational = 1
    case usage = 2
    case malformed = 4
    case `internal` = 5
}

private struct Diagnostic: Encodable {
    var type: String
    var severity: String
    var message: String
    var detectedAt: String
    var targetRoot: String?
    var agent: String?
    var uid: String?
    var version: Int?

    init(
        type: String,
        severity: String,
        message: String,
        targetRoot: String? = nil,
        agent: String? = nil,
        uid: String? = nil,
        version: Int? = nil
    ) {
        self.type = type
        self.severity = severity
        self.message = message
        self.detectedAt = ResolverClock.now()
        self.targetRoot = targetRoot
        self.agent = agent
        self.uid = uid
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case severity
        case message
        case detectedAt = "detected_at"
        case targetRoot = "target_root"
        case agent
        case uid
        case version
    }
}

private struct TriggerInstruction: Encodable {
    var uid: String
    var version: Int
    var name: String
    var description: String
    var trigger: String
    var tags: [String]
}

private struct SpecInstruction: Encodable {
    var uid: String
    var version: Int
    var name: String
    var content: String
}

private struct TriggerEnvelope: Encodable {
    var instructions: [TriggerInstruction]
    var diagnostics: [Diagnostic]
}

private struct SpecEnvelope: Encodable {
    var instruction: SpecInstruction?
    var diagnostics: [Diagnostic]

    private enum CodingKeys: String, CodingKey {
        case instruction
        case diagnostics
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let instruction {
            try container.encode(instruction, forKey: .instruction)
        } else {
            try container.encodeNil(forKey: .instruction)
        }
        try container.encode(diagnostics, forKey: .diagnostics)
    }
}

private struct ResolverContext {
    var targetRoot: URL
    var packageRoot: URL
    var targetRegistry: [String: Any]
    var installedRegistryPath: String
    var instructionStorePath: String
}

private struct ContextResult {
    var context: ResolverContext?
    var diagnostics: [Diagnostic]
}

private enum ResolverClock {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }
}

private enum Resolver {
    private static let fileManager = FileManager.default

    static func run(_ argv: [String]) -> Int32 {
        guard argv.count >= 2 else {
            return emit(
                TriggerEnvelope(
                    instructions: [],
                    diagnostics: [
                        Diagnostic(type: "invalid_cli_usage", severity: "error", message: "Missing command.")
                    ]
                ),
                code: .usage
            )
        }

        let command = argv[1]
        let args = Array(argv.dropFirst(2))

        do {
            let target = try requireArg(args, "--target")
            let agent = try requireArg(args, "--agent")
            let harnessRoot = optionalArg(args, "--harness-root")

            switch command {
            case "list-triggers":
                return listTriggers(target: target, harnessRoot: harnessRoot, agent: agent)
            case "read-spec":
                let uid = try requireArg(args, "--uid")
                let versionString = try requireArg(args, "--version")
                guard let version = Int(versionString) else {
                    throw ArgumentError("Invalid --version")
                }
                return readSpec(target: target, harnessRoot: harnessRoot, agent: agent, uid: uid, version: max(version, 1))
            default:
                return emit(
                    TriggerEnvelope(
                        instructions: [],
                        diagnostics: [
                            Diagnostic(type: "invalid_cli_usage", severity: "error", message: "Unknown command: \(command)")
                        ]
                    ),
                    code: .usage
                )
            }
        } catch let error as ArgumentError {
            return emit(
                TriggerEnvelope(
                    instructions: [],
                    diagnostics: [
                        Diagnostic(type: "invalid_cli_usage", severity: "error", message: error.message)
                    ]
                ),
                code: .usage
            )
        } catch {
            return emit(
                TriggerEnvelope(
                    instructions: [],
                    diagnostics: [
                        Diagnostic(type: "internal_error", severity: "error", message: String(describing: error))
                    ]
                ),
                code: .internal
            )
        }
    }

    private static func listTriggers(target: String, harnessRoot: String?, agent: String) -> Int32 {
        let contextResult = readContexts(target: target, harnessRoot: harnessRoot, agent: agent)
        var diagnostics = contextResult.diagnostics
        var instructions: [TriggerInstruction] = []
        var refs: [(uid: String, version: Int, context: ResolverContext)] = []
        var seenRefs = Set<String>()

        for context in contextResult.contexts {
            for item in array(from: context.targetRegistry["instructions"]) {
                guard let ref = item as? [String: Any],
                      let uid = ref["uid"] as? String,
                      let version = intValue(ref["version"])
                else {
                    diagnostics.append(Diagnostic(
                        type: "malformed_instruction_ref",
                        severity: "warning",
                        message: "Target registry contains an instruction reference without uid and integer version.",
                        targetRoot: context.targetRoot.path,
                        agent: agent
                    ))
                    continue
                }

                let refKey = key(uid: uid, version: version)
                guard seenRefs.insert(refKey).inserted else {
                    continue
                }

                refs.append((uid: uid, version: version, context: context))
            }
        }

        guard !refs.isEmpty else {
            return emit(TriggerEnvelope(instructions: [], diagnostics: diagnostics), code: .success)
        }

        var registryCache: [String: [String: [String: Any]]] = [:]

        for ref in refs {
            let registry = registryCache[ref.context.installedRegistryPath] ?? {
                let registry = systemRegistry(path: ref.context.installedRegistryPath)
                diagnostics.append(contentsOf: registry.diagnostics)
                registryCache[ref.context.installedRegistryPath] = registry.instructions
                return registry.instructions
            }()

            guard let metadata = registry[key(uid: ref.uid, version: ref.version)] else {
                diagnostics.append(Diagnostic(
                    type: "missing_instruction_version",
                    severity: "warning",
                    message: "Target references \(ref.uid)@\(ref.version), but that version is not installed.",
                    targetRoot: ref.context.targetRoot.path,
                    agent: agent,
                    uid: ref.uid,
                    version: ref.version
                ))
                continue
            }

            guard fileManager.fileExists(atPath: specURL(uid: ref.uid, version: ref.version, instructionStorePath: ref.context.instructionStorePath).path) else {
                diagnostics.append(Diagnostic(
                    type: "missing_instruction_spec",
                    severity: "warning",
                    message: "Target references \(ref.uid)@\(ref.version), but its SPEC.md file is missing.",
                    targetRoot: ref.context.targetRoot.path,
                    agent: agent,
                    uid: ref.uid,
                    version: ref.version
                ))
                continue
            }

            instructions.append(TriggerInstruction(
                uid: ref.uid,
                version: ref.version,
                name: string(metadata["name"]),
                description: string(metadata["description"]),
                trigger: string(metadata["trigger"]),
                tags: stringArray(metadata["tags"])
            ))
        }

        return emit(TriggerEnvelope(instructions: instructions, diagnostics: diagnostics), code: .success)
    }

    private static func readSpec(target: String, harnessRoot: String?, agent: String, uid: String, version: Int) -> Int32 {
        let contextResult = readContexts(target: target, harnessRoot: harnessRoot, agent: agent)
        var diagnostics = contextResult.diagnostics
        guard !contextResult.contexts.isEmpty else {
            return emit(SpecEnvelope(instruction: nil, diagnostics: diagnostics), code: .success)
        }

        var pinnedContext: ResolverContext?
        for context in contextResult.contexts {
            let isPinned = array(from: context.targetRegistry["instructions"]).contains { item in
                guard let ref = item as? [String: Any] else {
                    return false
                }
                return ref["uid"] as? String == uid && intValue(ref["version"]) == version
            }

            if isPinned {
                pinnedContext = context
                break
            }
        }

        guard let context = pinnedContext else {
            diagnostics.append(Diagnostic(
                type: "instruction_not_pinned",
                severity: "warning",
                message: "\(uid)@\(version) is not pinned in any loaded target or harness registry for agent '\(agent)'.",
                targetRoot: normalizedURL(for: target).path,
                agent: agent,
                uid: uid,
                version: version
            ))
            return emit(SpecEnvelope(instruction: nil, diagnostics: diagnostics), code: .operational)
        }

        let registry = systemRegistry(path: context.installedRegistryPath)
        diagnostics.append(contentsOf: registry.diagnostics)
        let metadata = registry.instructions[key(uid: uid, version: version)]
        let path = specURL(uid: uid, version: version, instructionStorePath: context.instructionStorePath)

        guard let metadata, fileManager.fileExists(atPath: path.path) else {
            diagnostics.append(Diagnostic(
                type: "missing_instruction_version",
                severity: "warning",
                message: "\(uid)@\(version) is not installed on this machine.",
                targetRoot: context.targetRoot.path,
                agent: agent,
                uid: uid,
                version: version
            ))
            return emit(SpecEnvelope(instruction: nil, diagnostics: diagnostics), code: .success)
        }

        do {
            let content = try String(contentsOf: path, encoding: .utf8)
            return emit(
                SpecEnvelope(
                    instruction: SpecInstruction(
                        uid: uid,
                        version: version,
                        name: string(metadata["name"]),
                        content: content
                    ),
                    diagnostics: diagnostics
                ),
                code: .success
            )
        } catch {
            diagnostics.append(Diagnostic(
                type: "read_spec_failed",
                severity: "error",
                message: "Could not read SPEC.md for \(uid)@\(version): \(error)",
                targetRoot: context.targetRoot.path,
                agent: agent,
                uid: uid,
                version: version
            ))
            return emit(SpecEnvelope(instruction: nil, diagnostics: diagnostics), code: .operational)
        }
    }

    private static func readContexts(target: String, harnessRoot: String?, agent: String) -> (contexts: [ResolverContext], diagnostics: [Diagnostic]) {
        var contexts: [ResolverContext] = []
        var diagnostics: [Diagnostic] = []
        var seenPackages = Set<String>()
        let candidates = [target, harnessRoot].compactMap { candidate -> String? in
            guard let candidate else {
                return nil
            }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        for candidate in candidates {
            let result = readContext(target: candidate, agent: agent)
            diagnostics.append(contentsOf: result.diagnostics)

            guard let context = result.context else {
                continue
            }

            let packagePath = context.packageRoot.path
            guard seenPackages.insert(packagePath).inserted else {
                continue
            }

            contexts.append(context)
        }

        return (contexts, diagnostics)
    }

    private static func readContext(target: String, agent: String) -> ContextResult {
        let found = findContext(target: target)
        guard let targetRoot = found.targetRoot,
              let packageRoot = found.packageRoot,
              let manifestURL = found.manifestURL
        else {
            return ContextResult(
                context: nil,
                diagnostics: []
            )
        }

        let manifest: [String: Any]
        do {
            manifest = try loadObject(at: manifestURL)
        } catch {
            return ContextResult(
                context: nil,
                diagnostics: [
                    Diagnostic(
                        type: "malformed_manifest",
                        severity: "error",
                        message: "Could not read .agent-context/manifest.json: \(error)",
                        targetRoot: targetRoot.path,
                        agent: agent
                    )
                ]
            )
        }

        guard let entrypoints = manifest["entrypoints"] as? [String: Any],
              let registries = entrypoints["instruction_registries"] as? [String: Any]
        else {
            return ContextResult(
                context: nil,
                diagnostics: [
                    Diagnostic(
                        type: "malformed_manifest",
                        severity: "error",
                        message: "The manifest does not contain an instruction_registries entrypoint.",
                        targetRoot: targetRoot.path,
                        agent: agent
                    )
                ]
            )
        }

        guard let registryName = registries[agent] as? String else {
            return ContextResult(context: nil, diagnostics: [])
        }

        let installedRegistryPath = entrypoints["installed_registry"] as? String ?? "~/.spellbook/registry/registry.json"
        let paths = manifest["paths"] as? [String: Any]
        let instructionStorePath = paths?["instruction_store"] as? String ?? "~/.spellbook/instructions/"
        let registryURL = packageRoot.appendingPathComponent(registryName)

        let targetRegistry: [String: Any]
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return ContextResult(
                context: ResolverContext(
                    targetRoot: targetRoot,
                    packageRoot: packageRoot,
                    targetRegistry: ["agent": agent, "instructions": []],
                    installedRegistryPath: installedRegistryPath,
                    instructionStorePath: instructionStorePath
                ),
                diagnostics: []
            )
        }

        do {
            targetRegistry = try loadObject(at: registryURL)
        } catch {
            return ContextResult(
                context: nil,
                diagnostics: [
                    Diagnostic(
                        type: "malformed_target_registry",
                        severity: "error",
                        message: "Could not read \(registryName): \(error)",
                        targetRoot: targetRoot.path,
                        agent: agent
                    )
                ]
            )
        }

        guard targetRegistry["agent"] as? String == agent,
              targetRegistry["instructions"] is [Any]
        else {
            return ContextResult(
                context: nil,
                diagnostics: [
                    Diagnostic(
                        type: "malformed_target_registry",
                        severity: "error",
                        message: "\(registryName) is not a valid registry for agent '\(agent)'.",
                        targetRoot: targetRoot.path,
                        agent: agent
                    )
                ]
            )
        }

        return ContextResult(
            context: ResolverContext(
                targetRoot: targetRoot,
                packageRoot: packageRoot,
                targetRegistry: targetRegistry,
                installedRegistryPath: installedRegistryPath,
                instructionStorePath: instructionStorePath
            ),
            diagnostics: []
        )
    }

    private static func findContext(target: String) -> (targetRoot: URL?, packageRoot: URL?, manifestURL: URL?) {
        let targetURL = normalizedURL(for: target)
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
        var current = exists && isDirectory.boolValue ? targetURL : targetURL.deletingLastPathComponent()

        while true {
            let packageRoot = current.appendingPathComponent(".agent-context", isDirectory: true)
            let manifestURL = packageRoot.appendingPathComponent("manifest.json")
            if fileManager.fileExists(atPath: manifestURL.path) {
                return (current, packageRoot, manifestURL)
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return (nil, nil, nil)
            }
            current = parent
        }
    }

    private static func systemRegistry(path: String?) -> (instructions: [String: [String: Any]], diagnostics: [Diagnostic]) {
        let registryURL = normalizedURL(for: path ?? "~/.spellbook/registry/registry.json")
        do {
            let payload = try loadObject(at: registryURL)
            let items = array(from: payload["instructions"])
            var index: [String: [String: Any]] = [:]

            for item in items {
                guard let metadata = item as? [String: Any],
                      let uid = metadata["uid"] as? String,
                      let version = intValue(metadata["version"])
                else {
                    continue
                }
                index[key(uid: uid, version: version)] = metadata
            }

            return (index, [])
        } catch {
            return (
                [:],
                [Diagnostic(type: "malformed_system_registry", severity: "error", message: "Could not read system registry: \(error)")]
            )
        }
    }

    private static func specURL(uid: String, version: Int, instructionStorePath: String?) -> URL {
        normalizedURL(for: instructionStorePath ?? "~/.spellbook/instructions/")
            .appendingPathComponent(uid, isDirectory: true)
            .appendingPathComponent("\(max(version, 1))", isDirectory: true)
            .appendingPathComponent("SPEC.md")
    }

    private static func loadObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ResolverError("JSON root is not an object")
        }
        return dictionary
    }

    private static func normalizedURL(for path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func requireArg(_ args: [String], _ name: String) throws -> String {
        guard let index = args.firstIndex(of: name),
              args.indices.contains(index + 1)
        else {
            throw ArgumentError("Missing \(name)")
        }
        return args[index + 1]
    }

    private static func optionalArg(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name),
              args.indices.contains(index + 1)
        else {
            return nil
        }
        return args[index + 1]
    }

    private static func emit<T: Encodable>(_ payload: T, code: ResolverExit) -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(payload)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return code.rawValue
        } catch {
            let fallback = #"{"diagnostics":[{"type":"internal_error","severity":"error","message":"Could not encode resolver output."}],"instructions":[]}"#
            FileHandle.standardOutput.write(Data(fallback.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return ResolverExit.internal.rawValue
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return number.intValue
        }
        return nil
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func array(from value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func key(uid: String, version: Int) -> String {
        "\(uid)@\(version)"
    }
}

private struct ArgumentError: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

private struct ResolverError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

exit(Resolver.run(CommandLine.arguments))
