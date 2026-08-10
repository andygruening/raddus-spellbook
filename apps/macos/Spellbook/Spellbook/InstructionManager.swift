import Foundation

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
        let spellsURL = directory.appending(path: "spells.json")
        let stagingURL = directory.appending(path: "spells-staging.json")
        let archiveURL = directory.appending(path: "spells-archive.json")
        let existingContent = try? String(contentsOf: target, encoding: .utf8)
        let targetExists = existingContent != nil
        let nextContent = try contentByApplyingManagedBlock(to: existingContent ?? "", targetInstructionURL: target)
        let action: ManagedBlockAction = existingContent?.contains(startMarker) == true ? .update : .add

        return InstructionPreview(
            targetInstructionURL: target,
            targetExists: targetExists,
            spellsURL: spellsURL,
            spellsExists: FileManager.default.fileExists(atPath: spellsURL.path(percentEncoded: false)),
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
        try nextContent.write(to: preview.targetInstructionURL, atomically: true, encoding: .utf8)

        if !FileManager.default.fileExists(atPath: preview.spellsURL.path(percentEncoded: false)) {
            let data = try JSONEncoder.spellbook.encode(SpellRegistry.empty)
            try data.write(to: preview.spellsURL, options: [.atomic])
        }

        if !FileManager.default.fileExists(atPath: preview.stagingURL.path(percentEncoded: false)) {
            let data = try JSONEncoder.spellbook.encode(SpellRegistry.empty)
            try data.write(to: preview.stagingURL, options: [.atomic])
        }

        if !FileManager.default.fileExists(atPath: preview.archiveURL.path(percentEncoded: false)) {
            let data = try JSONEncoder.spellbook.encode(SpellRegistry.empty)
            try data.write(to: preview.archiveURL, options: [.atomic])
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
        ## Spellbook Instruction Registry

        Selected instruction file target: FILE_TARGET

        For every task, use Spellbook in two ways:

        1. Query installed spells before and during the work.
           Treat the selected target directory's spells.json like a local MCP server or instruction registry. Resolve it relative to the directory that contains FILE_TARGET, not relative to the project root or current working directory.

           Read spells.json as an index first. Inspect each spell's trigger first, then its name, description, and tags if more context is needed, to decide whether it should activate for the current task. Do not eagerly read every spell markdown file. When a spell's trigger matches the current task, read its referenced file path, usually spells/<spell>.md, from the same selected target directory and apply that instruction.

           Staged entries are review-only. Do not read or activate spells-staging.json during task execution.

        2. Track new reusable instructions while working.
           When you identify a durable instruction, workflow convention, project setup requirement, review rule, or reusable feedback pattern, write a staged index entry to spells-staging.json in the selected target directory, and write the full markdown instructions to a new spells/<spell>.md file under that same directory. Capture broadly useful instructions, not only review guidance; for example, a preference that web apps should be set up so they are deployable to Cloudflare is a valid spell.

           During capture, do not modify spells.json and do not overwrite existing installed spell files unless explicitly asked.

        Keep spells.json, spells-staging.json, and spells-archive.json valid JSON:

        ```json
        {
          "version": 1,
          "spells": [
            {
              "name": "Cloudflare-deployable web apps",
              "description": "Set up web apps so they can be deployed to Cloudflare.",
              "trigger": "Use when building or restructuring a web app, site, dashboard, or frontend tool that should be deployable.",
              "tags": ["deployment", "cloudflare", "web"],
              "file": "spells/cloudflare-deployable-web-apps.md"
            }
          ]
        }
        ```

        Each spell index entry should include uid when available, name, description, trigger, tags, and file. The trigger must describe when the agent should activate the spell. Use a relative file value such as "spells/cloudflare-deployable-web-apps.md". Keep the full durable instruction, trigger, safe path, and any supporting details in the referenced markdown file.

        Update existing matching spells instead of duplicating them. Do not include secrets, private customer data, or one-off observations.
        \(endMarker)
        """
    }
}

struct InstructionPreview: Equatable {
    var targetInstructionURL: URL
    var targetExists: Bool
    var spellsURL: URL
    var spellsExists: Bool
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
