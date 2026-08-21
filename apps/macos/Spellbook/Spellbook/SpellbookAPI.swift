import Foundation

final class SpellbookAPI {
    static let shared = SpellbookAPI()

    private let baseURL = URL(string: "https://api.spellbook.raddus.dev/")!
    private let decoder = JSONDecoder.spellbook
    private let encoder = JSONEncoder()

    private init() {}

    func requestOTP(email: String) async throws {
        let _: OTPRequestResponse = try await send(
            path: "/api/auth/request-otp",
            method: "POST",
            body: ["email": email],
            token: nil,
            operation: .requestSignInCode
        )
    }

    func verifyOTP(email: String, code: String) async throws -> SpellbookSession {
        let response: VerifyOTPResponse = try await send(
            path: "/api/auth/verify-otp",
            method: "POST",
            body: ["email": email, "code": code],
            token: nil,
            operation: .verifySignInCode
        )

        return SpellbookSession(token: response.token, email: response.email, expiresAt: response.expiresAt)
    }

    func publicSpells(token: String? = nil) async throws -> [Spell] {
        try await publicRules(token: token)
    }

    func publicRules(token: String? = nil) async throws -> [Spell] {
        let response: SpellsResponse = try await send(
            path: "/api/rules/public?limit=100",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadPublicRules
        )
        return response.spells
    }

    func publicSpell(uid: String, token: String? = nil) async throws -> Spell {
        try await publicRule(uid: uid, token: token)
    }

    func publicRule(uid: String, token: String? = nil) async throws -> Spell {
        let response: SpellEnvelope = try await send(
            path: "/api/rules/\(uid.spellbookPathComponent)",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadPublicRules
        )
        return response.spell
    }

    func publicSpell(uid: String, version: Int, token: String? = nil) async throws -> Spell {
        try await publicRule(uid: uid, version: version, token: token)
    }

    func publicRule(uid: String, version: Int, token: String? = nil) async throws -> Spell {
        let response: SpellEnvelope = try await send(
            path: "/api/rules/\(uid.spellbookPathComponent)/versions/\(max(version, 1))",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadPublicRules
        )
        return response.spell
    }

    func mySpells(token: String) async throws -> [Spell] {
        try await myRules(token: token)
    }

    func myRules(token: String) async throws -> [Spell] {
        let response: SpellsResponse = try await send(
            path: "/api/rules/mine",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadMyRules
        )
        return response.spells
    }

    func publish(spell: Spell, token: String) async throws -> Spell {
        try await saveRuleDraft(spell: spell, token: token)
    }

    func createRuleDraft(spell: Spell, token: String) async throws -> Spell {
        let body = RuleDraftBody(spell: spell)
        let response: SpellEnvelope = try await send(
            path: "/api/rules",
            method: "POST",
            body: body,
            token: token,
            operation: .saveRuleDraft
        )
        return response.spell
    }

    func saveRuleDraft(spell: Spell, token: String) async throws -> Spell {
        guard let uid = spell.uid?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            return try await createRuleDraft(spell: spell, token: token)
        }

        let body = RuleDraftBody(spell: spell)
        let response: SpellEnvelope = try await send(
            path: "/api/rules/\(uid.spellbookPathComponent)/draft",
            method: "PATCH",
            body: body,
            token: token,
            operation: .saveRuleDraft
        )
        return response.spell
    }

    func submitRuleDraft(uid: String, version: Int, token: String) async throws -> Spell {
        let response: SpellEnvelope = try await send(
            path: "/api/rules/\(uid.spellbookPathComponent)/submit",
            method: "POST",
            body: Optional<String>.none,
            token: token,
            operation: .submitRuleDraft
        )
        return response.spell
    }

    func finishRule(uid: String, version: Int, token: String) async throws -> Spell {
        let rule = try await publicRule(uid: uid, version: version, token: token)
        guard rule.lifecycleState == .approved else {
            throw SpellbookError.message("This rule is not approved yet.")
        }
        return rule
    }

    func publicPacks(token: String? = nil) async throws -> [RulePack] {
        let response: PacksResponse = try await send(
            path: "/api/packs/public?limit=100",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadPublicPacks
        )
        return response.packs
    }

    func delete(uid: String, token: String) async throws {
        let _: DeleteResponse = try await send(
            path: "/api/rules/\(uid.spellbookPathComponent)",
            method: "DELETE",
            body: Optional<String>.none,
            token: token,
            operation: .deleteSpell
        )
    }

    func setStarred(uid: String, starred: Bool, token: String) async throws -> Spell {
        let response: SpellEnvelope = try await send(
            path: "/api/rules/\(uid.spellbookPathComponent)/star",
            method: starred ? "POST" : "DELETE",
            body: Optional<String>.none,
            token: token,
            operation: starred ? .starSpell : .unstarSpell
        )
        return response.spell
    }

    func dynamicSpellLink(uid: String) -> URL {
        dynamicRuleLink(uid: uid)
    }

    func dynamicRuleLink(uid: String) -> URL {
        baseURL.spellbookAPIURL(path: "/open/\(uid.spellbookPathComponent)")
    }

    private func send<ResponseBody: Decodable, RequestBody: Encodable>(
        path: String,
        method: String,
        body: RequestBody?,
        token: String?,
        operation: SpellbookAPIOperation
    ) async throws -> ResponseBody {
        var request = URLRequest(url: baseURL.spellbookAPIURL(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpellbookError.message(
                "\(operation.failurePrefix) Spellbook could not reach \(baseURL.host() ?? "the server"). Check your connection and confirm the Worker is deployed."
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpellbookError.message("\(operation.failurePrefix) Spellbook could not read the server response.")
        }

        if httpResponse.statusCode == 401 {
            throw SpellbookError.expiredSession
        }

        if httpResponse.statusCode == 404, isMissingPublishedSpellResponse(data) {
            throw SpellbookError.missingPublishedSpell
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SpellbookError.message(productSafeError(from: data, statusCode: httpResponse.statusCode, operation: operation))
        }

        do {
            return try decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw SpellbookError.message("\(operation.failurePrefix) Spellbook could not read the server response.")
        }
    }

    private func isMissingPublishedSpellResponse(_ data: Data) -> Bool {
        let response = try? decoder.decode(APIErrorResponse.self, from: data)
        let error = response?.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return error == "Spell not found." || error == "Rule not found."
    }

    private func productSafeError(from data: Data, statusCode: Int, operation: SpellbookAPIOperation) -> String {
        let response = try? decoder.decode(APIErrorResponse.self, from: data)
        let serverMessage = response?.error.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String

        if let serverMessage, !serverMessage.isEmpty {
            message = rewrittenServerMessage(serverMessage, statusCode: statusCode, operation: operation)
        } else if statusCode == 404 {
            message = "The deployed Worker does not have the Spellbook endpoint for this action. Deploy the latest Worker."
        } else if statusCode >= 500 {
            message = "The Spellbook API had a server-side problem while handling this action. Check the Worker logs."
        } else {
            message = "The Spellbook server could not complete this action."
        }

        if let requestId = response?.requestId, !requestId.isEmpty {
            return "\(operation.failurePrefix) \(message)\nRequest ID: \(requestId)"
        }

        return "\(operation.failurePrefix) \(message)"
    }

    private func rewrittenServerMessage(_ serverMessage: String, statusCode: Int, operation: SpellbookAPIOperation) -> String {
        if serverMessage == "Spellbook had trouble completing that request." {
            return "The deployed Worker returned an older generic error. Redeploy the latest Worker, then check the Worker logs if it continues."
        }

        if statusCode == 404 && serverMessage == "That Spellbook endpoint was not found." {
            return "The deployed Worker does not have the endpoint for \(operation.shortName). Deploy the latest Worker."
        }

        return serverMessage
    }
}

private enum SpellbookAPIOperation {
    case requestSignInCode
    case verifySignInCode
    case loadPublishedSpells
    case loadPublicRules
    case loadMyRules
    case loadPublicPacks
    case publishSpell
    case saveRuleDraft
    case submitRuleDraft
    case finishRule
    case deleteSpell
    case starSpell
    case unstarSpell

    var failurePrefix: String {
        switch self {
        case .requestSignInCode:
            return "Could not send the sign-in code."
        case .verifySignInCode:
            return "Could not verify the sign-in code."
        case .loadPublishedSpells:
            return "Could not load published rules."
        case .loadPublicRules:
            return "Could not load public rules."
        case .loadMyRules:
            return "Could not load your rules."
        case .loadPublicPacks:
            return "Could not load packs."
        case .publishSpell:
            return "Could not save this rule."
        case .saveRuleDraft:
            return "Could not save this rule draft."
        case .submitRuleDraft:
            return "Could not submit this rule for review."
        case .finishRule:
            return "Could not finish this rule."
        case .deleteSpell:
            return "Could not delete this rule."
        case .starSpell:
            return "Could not star this rule."
        case .unstarSpell:
            return "Could not remove your star."
        }
    }

    var shortName: String {
        switch self {
        case .requestSignInCode:
            return "sending sign-in codes"
        case .verifySignInCode:
            return "verifying sign-in codes"
        case .loadPublishedSpells:
            return "loading published rules"
        case .loadPublicRules:
            return "loading public rules"
        case .loadMyRules:
            return "loading your rules"
        case .loadPublicPacks:
            return "loading packs"
        case .publishSpell:
            return "saving rules"
        case .saveRuleDraft:
            return "saving rule drafts"
        case .submitRuleDraft:
            return "submitting rule drafts"
        case .finishRule:
            return "finishing rules"
        case .deleteSpell:
            return "deleting rules"
        case .starSpell:
            return "starring rules"
        case .unstarSpell:
            return "removing stars"
        }
    }
}

private struct OTPRequestResponse: Decodable {
    var ok: Bool
    var expiresAt: String
}

private struct VerifyOTPResponse: Decodable {
    var token: String
    var email: String
    var expiresAt: String
}

private struct SpellsResponse: Decodable {
    var spells: [Spell]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spells = try container.decodeIfPresent([Spell].self, forKey: .rules)
            ?? container.decodeIfPresent([Spell].self, forKey: .spells)
            ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case rules
        case spells
    }
}

private struct SpellEnvelope: Decodable {
    var spell: Spell

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spell = try container.decodeIfPresent(Spell.self, forKey: .rule)
            ?? container.decode(Spell.self, forKey: .spell)
    }

    private enum CodingKeys: String, CodingKey {
        case rule
        case spell
    }
}

private struct PacksResponse: Decodable {
    var packs: [RulePack]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packs = try container.decodeIfPresent([RulePack].self, forKey: .packs) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case packs
    }
}

private struct DeleteResponse: Decodable {
    var ok: Bool
}

private struct APIErrorResponse: Decodable {
    var error: String
    var requestId: String?
}

private struct RuleDraftBody: Encodable {
    var uid: String?
    var name: String
    var description: String
    var appliesWhen: String
    var file: String
    var body: String

    init(spell: Spell) {
        uid = spell.uid
        name = spell.name
        description = spell.description
        appliesWhen = spell.trigger
        file = RuleDraftBody.normalizedFilePath(for: spell)
        body = spell.content ?? ""
    }

    private static func normalizedFilePath(for spell: Spell) -> String {
        let file = spell.file.trimmingCharacters(in: .whitespacesAndNewlines)
        if file == "SPEC.md" || (!file.hasPrefix("/") && !file.contains("..") && file.hasSuffix(".md")) {
            return file
        }

        return "SPEC.md"
    }

    private enum CodingKeys: String, CodingKey {
        case uid
        case name
        case description
        case appliesWhen
        case file
        case body
    }
}

private extension URL {
    func spellbookAPIURL(path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.path = parts[0].hasPrefix("/") ? parts[0] : "/\(parts[0])"
        if parts.count == 2 {
            components?.percentEncodedQuery = parts[1]
        }

        return components?.url ?? self
    }
}

private extension String {
    var spellbookPathComponent: String {
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/")
        return addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? self
    }
}
