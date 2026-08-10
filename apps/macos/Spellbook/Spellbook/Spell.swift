import Foundation

struct Spell: Identifiable, Codable, Equatable {
    var uid: String?
    var name: String
    var description: String
    var trigger: String
    var tags: [String]
    var file: String
    var content: String?
    var ownerEmail: String?
    var publishedAt: String?
    var starCount: Int
    var starredByMe: Bool

    var id: String {
        uid ?? file
    }

    init(
        uid: String? = nil,
        name: String,
        description: String,
        trigger: String = "",
        tags: [String] = ["review"],
        file: String = "",
        content: String? = nil,
        ownerEmail: String? = nil,
        publishedAt: String? = nil,
        starCount: Int = 0,
        starredByMe: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.description = description
        self.trigger = trigger
        self.tags = tags
        self.file = file
        self.content = content
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
        name = decodedName
        description = decodedDescription
        trigger = decodedTrigger ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? ["review"]
        file = try container.decodeIfPresent(String.self, forKey: .file)
            ?? "spells/\(Spell.slug(for: decodedName)).md"
        content = decodedContent ?? Spell.legacyMarkdown(from: container, name: decodedName)
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
        try container.encode(tags, forKey: .tags)
        try container.encode(file, forKey: .file)
    }

    func matchesForInstall(_ other: Spell) -> Bool {
        if let uid, let otherUID = other.uid, uid == otherUID {
            return true
        }

        return normalized(name) == normalized(other.name)
            && normalized(description) == normalized(other.description)
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
        case name
        case description
        case tags
        case file
        case content
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
    }
}

struct SpellRegistry: Codable {
    var version: Int
    var spells: [Spell]

    static let empty = SpellRegistry(version: 1, spells: [])
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
