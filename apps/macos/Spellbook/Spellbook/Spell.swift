import Foundation

struct Spell: Identifiable, Codable, Equatable {
    var uid: String?
    var localID: String?
    var name: String
    var description: String
    var trigger: String
    var file: String
    var content: String?
    var version: Int
    var ownerEmail: String?
    var publishedAt: String?
    var starCount: Int
    var starredByMe: Bool

    var id: String {
        if let uid {
            return "\(uid)@\(normalizedVersion)"
        }
        return localID ?? file
    }

    var storageID: String {
        uid ?? localID ?? Spell.slug(for: name)
    }

    var normalizedVersion: Int {
        max(version, 1)
    }

    init(
        uid: String? = nil,
        localID: String? = nil,
        name: String,
        description: String,
        trigger: String = "",
        file: String = "",
        content: String? = nil,
        version: Int = 1,
        ownerEmail: String? = nil,
        publishedAt: String? = nil,
        starCount: Int = 0,
        starredByMe: Bool = false
    ) {
        self.uid = uid
        self.localID = localID
        self.name = name
        self.description = description
        self.trigger = trigger
        self.file = file
        self.content = content
        self.version = max(version, 1)
        self.ownerEmail = ownerEmail
        self.publishedAt = publishedAt
        self.starCount = starCount
        self.starredByMe = starredByMe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? "Untitled spell"
        let decodedDescription = try container.decodeIfPresent(String.self, forKey: .description)
            ?? container.decodeIfPresent(String.self, forKey: .requirement)
            ?? "Reusable review instruction."
        let decodedContent = try container.decodeIfPresent(String.self, forKey: .content)
        let decodedTrigger = try container.decodeIfPresent(String.self, forKey: .trigger)
            ?? decodedContent.flatMap { Spell.trigger(from: $0) }

        uid = try container.decodeIfPresent(String.self, forKey: .uid)
            ?? container.decodeIfPresent(String.self, forKey: .remoteId)
        localID = try container.decodeIfPresent(String.self, forKey: .localID)
            ?? container.decodeIfPresent(String.self, forKey: .localId)
        name = decodedName
        description = decodedDescription
        trigger = decodedTrigger ?? ""
        let decodedFile = try container.decodeIfPresent(String.self, forKey: .file)
            ?? "\(AgentContextLayout.instructionsDirectoryName)/\(Spell.slug(for: decodedName)).md"
        file = AgentContextLayout.canonicalInstructionFilePath(decodedFile)
        content = decodedContent ?? Spell.legacyMarkdown(from: container, name: decodedName)
        version = max(try container.decodeIfPresent(Int.self, forKey: .version) ?? 1, 1)
        ownerEmail = try container.decodeIfPresent(String.self, forKey: .ownerEmail)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        starCount = try container.decodeIfPresent(Int.self, forKey: .starCount) ?? 0
        starredByMe = try container.decodeIfPresent(Bool.self, forKey: .starredByMe) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(trigger, forKey: .trigger)
        if !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(file, forKey: .file)
        }
        try container.encode(normalizedVersion, forKey: .version)
    }

    func matchesForInstall(_ other: Spell) -> Bool {
        if let uid, let otherUID = other.uid, uid == otherUID {
            return normalizedVersion == other.normalizedVersion
        }

        if let localID, let otherLocalID = other.localID, localID == otherLocalID {
            return true
        }

        return normalized(name) == normalized(other.name)
            && normalized(description) == normalized(other.description)
    }

    func hasSameIdentity(as other: Spell) -> Bool {
        if id == other.id {
            return true
        }

        if let uid, let otherUID = other.uid, uid == otherUID {
            return normalizedVersion == other.normalizedVersion
        }

        if let localID, let otherLocalID = other.localID, localID == otherLocalID {
            return true
        }

        return false
    }

    static func slug(for value: String) -> String {
        let normalized = value
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let collapsed = String(normalized)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "spell" : collapsed
    }

    static func trigger(from markdown: String) -> String? {
        section(named: "Trigger", in: markdown)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func section(named heading: String, in markdown: String) -> String? {
        var isCollecting = false
        var lines: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("#") {
                let headingText = String(trimmedLine.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                if isCollecting {
                    break
                }
                if headingText.caseInsensitiveCompare(heading) == .orderedSame {
                    isCollecting = true
                }
                continue
            }

            if isCollecting {
                lines.append(line)
            }
        }

        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func legacyMarkdown(from container: KeyedDecodingContainer<CodingKeys>, name: String) -> String? {
        let role = try? container.decodeIfPresent(String.self, forKey: .role)
        let category = try? container.decodeIfPresent(String.self, forKey: .category)
        let requirement = try? container.decodeIfPresent(String.self, forKey: .requirement)
        let trigger = try? container.decodeIfPresent(String.self, forKey: .trigger)
        let safePath = try? container.decodeIfPresent(String.self, forKey: .safePath)
        let sourceAgent = try? container.decodeIfPresent(String.self, forKey: .sourceAgent)
        guard role != nil || category != nil || requirement != nil || trigger != nil || safePath != nil || sourceAgent != nil else {
            return nil
        }

        var sections = ["# \(name)"]
        if let role, !role.isEmpty {
            sections.append("**Role:** \(role)")
        }
        if let category, !category.isEmpty {
            sections.append("**Category:** \(category)")
        }
        if let requirement, !requirement.isEmpty {
            sections.append("## Requirement\n\(requirement)")
        }
        if let trigger, !trigger.isEmpty {
            sections.append("## Trigger\n\(trigger)")
        }
        if let safePath, !safePath.isEmpty {
            sections.append("## Safe path\n\(safePath)")
        }
        if let sourceAgent, !sourceAgent.isEmpty {
            sections.append("**Source agent:** \(sourceAgent)")
        }

        return sections.joined(separator: "\n\n")
    }

    private enum CodingKeys: String, CodingKey {
        case uid
        case localID
        case name
        case description
        case file
        case content
        case version
        case ownerEmail
        case publishedAt
        case starCount
        case starredByMe

        case title
        case role
        case category
        case requirement
        case trigger
        case safePath
        case sourceAgent
        case remoteId
        case localId = "local_id"
    }
}

struct SpellRegistry: Codable {
    var schemaVersion: Int
    var spells: [Spell]
    var usesCompactEntries: Bool

    static let empty = SpellRegistry(schemaVersion: 1, spells: [], usesCompactEntries: true)

    init(schemaVersion: Int, spells: [Spell], usesCompactEntries: Bool = false) {
        self.schemaVersion = schemaVersion
        self.spells = spells
        self.usesCompactEntries = usesCompactEntries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .version)
            ?? 1

        if let compactEntries = try? container.decode([SpellRegistryEntry].self, forKey: .instructions) {
            usesCompactEntries = true
            spells = compactEntries.flatMap { entry in
                entry.versions.map { version in
                    Spell(
                        uid: entry.uid,
                        name: "",
                        description: "",
                        trigger: "",
                        version: version
                    )
                }
            }
        } else {
            usesCompactEntries = false
            spells = try container.decodeIfPresent([Spell].self, forKey: .instructions)
                ?? container.decodeIfPresent([Spell].self, forKey: .spells)
                ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(compactEntries, forKey: .instructions)
    }

    private var compactEntries: [SpellRegistryEntry] {
        var entries: [SpellRegistryEntry] = []
        var indexesByUID: [String: Int] = [:]

        for spell in spells {
            guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                continue
            }

            if let index = indexesByUID[uid] {
                entries[index].versions.insert(spell.normalizedVersion)
            } else {
                indexesByUID[uid] = entries.count
                entries.append(SpellRegistryEntry(uid: uid, versions: Set([spell.normalizedVersion])))
            }
        }

        return entries.map { entry in
            SpellRegistryEntry(uid: entry.uid, versions: entry.versions)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case version
        case instructions
        case spells
    }
}

private struct SpellRegistryEntry: Codable {
    var uid: String
    var versions: Set<Int>

    init(uid: String, versions: Set<Int>) {
        self.uid = uid
        self.versions = versions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        let decodedVersions = try container.decode([Int].self, forKey: .versions)
        versions = Set(decodedVersions.map { max($0, 1) })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(versions.sorted(), forKey: .versions)
    }

    private enum CodingKeys: String, CodingKey {
        case uid
        case versions
    }
}

struct TargetInstructionRef: Codable, Equatable, Hashable, Identifiable {
    var uid: String
    var version: Int

    var id: String {
        "\(uid)@\(version)"
    }

    init(uid: String, version: Int) {
        self.uid = uid
        self.version = max(version, 1)
    }
}

struct TargetInstructionRegistry: Codable, Equatable {
    var schemaVersion: Int
    var agent: String
    var instructions: [TargetInstructionRef]

    static func empty(agent: String) -> TargetInstructionRegistry {
        TargetInstructionRegistry(schemaVersion: 1, agent: agent, instructions: [])
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case agent
        case instructions
    }
}

struct SpellbookHarness: Identifiable, Codable, Equatable, Hashable {
    var file: String

    var id: String {
        file
    }

    var agent: String {
        AgentContextLayout.agentName(for: file)
    }

    init(file: String) {
        self.file = file
    }

    init(agent _: String, file: String, registry _: String) {
        self.file = file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
    }

    private enum CodingKeys: String, CodingKey {
        case file
    }
}

struct KnownTargetsRegistry: Codable, Equatable {
    var schemaVersion: Int
    var targets: [KnownTarget]

    static let empty = KnownTargetsRegistry(schemaVersion: 1, targets: [])

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case targets
    }
}

struct KnownTarget: Codable, Equatable, Identifiable {
    var root: String
    var harnessFiles: [String]

    var id: String {
        root
    }

    var harnesses: [SpellbookHarness] {
        harnessFiles.map { SpellbookHarness(file: $0) }
    }

    init(root: String, harnessFiles: [String]) {
        self.root = root
        self.harnessFiles = harnessFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decodeIfPresent(String.self, forKey: .root)
            ?? container.decode(String.self, forKey: .targetRoot)

        if let decodedFiles = try container.decodeIfPresent([String].self, forKey: .harnessFiles) {
            harnessFiles = decodedFiles
        } else if let decodedHarnesses = try container.decodeIfPresent([SpellbookHarness].self, forKey: .harnesses) {
            harnessFiles = decodedHarnesses.map(\.file)
        } else {
            harnessFiles = [InstructionManager.supportedFiles[0]]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(harnessFiles, forKey: .harnessFiles)
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case targetRoot = "target_root"
        case harnesses
        case harnessFiles = "harness_files"
    }
}

struct SpellbookDiagnostic: Codable, Equatable, Identifiable {
    var type: String
    var severity: String
    var targetRoot: String?
    var agent: String?
    var uid: String?
    var version: Int?
    var message: String
    var detectedAt: String

    var id: String {
        [
            type,
            severity,
            targetRoot ?? "",
            agent ?? "",
            uid ?? "",
            version.map(String.init) ?? "",
            message
        ].joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case severity
        case targetRoot = "target_root"
        case agent
        case uid
        case version
        case message
        case detectedAt = "detected_at"
    }
}

extension ISO8601DateFormatter {
    static let spellbook: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension JSONEncoder {
    static let spellbook: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension JSONDecoder {
    static let spellbook = JSONDecoder()
}
