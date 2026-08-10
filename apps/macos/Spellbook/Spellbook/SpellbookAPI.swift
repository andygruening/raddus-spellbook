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
        let response: SpellsResponse = try await send(
            path: "/api/spells/public?limit=100",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadPublishedSpells
        )
        return response.spells
    }

    func publicSpell(uid: String, token: String? = nil) async throws -> Spell {
        let response: SpellEnvelope = try await send(
            path: "/api/spells/\(uid)",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadPublishedSpells
        )
        return response.spell
    }

    func mySpells(token: String) async throws -> [Spell] {
        let response: SpellsResponse = try await send(
            path: "/api/spells/mine",
            method: "GET",
            body: Optional<String>.none,
            token: token,
            operation: .loadMySpells
        )
        return response.spells
    }

    func publish(spell: Spell, token: String) async throws -> Spell {
        let body = PublishSpellBody(spell: spell)
        let response: SpellEnvelope = try await send(
            path: "/api/spells",
            method: "POST",
            body: body,
            token: token,
            operation: .publishSpell
        )
        return response.spell
    }

    func delete(uid: String, token: String) async throws {
        let _: DeleteResponse = try await send(
            path: "/api/spells/\(uid)",
            method: "DELETE",
            body: Optional<String>.none,
            token: token,
            operation: .deleteSpell
        )
    }

    func setStarred(uid: String, starred: Bool, token: String) async throws -> Spell {
        let response: SpellEnvelope = try await send(
            path: "/api/spells/\(uid)/star",
            method: starred ? "POST" : "DELETE",
            body: Optional<String>.none,
            token: token,
            operation: starred ? .starSpell : .unstarSpell
        )
        return response.spell
    }

    func dynamicSpellLink(uid: String) -> URL {
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

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SpellbookError.message(productSafeError(from: data, statusCode: httpResponse.statusCode, operation: operation))
        }

        do {
            return try decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw SpellbookError.message("\(operation.failurePrefix) Spellbook could not read the server response.")
        }
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
    case loadMySpells
    case publishSpell
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
            return "Could not load published spells."
        case .loadMySpells:
            return "Could not load your published spells."
        case .publishSpell:
            return "Could not publish this spell."
        case .deleteSpell:
            return "Could not delete this spell."
        case .starSpell:
            return "Could not star this spell."
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
            return "loading published spells"
        case .loadMySpells:
            return "loading your spells"
        case .publishSpell:
            return "publishing spells"
        case .deleteSpell:
            return "deleting spells"
        case .starSpell:
            return "starring spells"
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
}

private struct SpellEnvelope: Decodable {
    var spell: Spell
}

private struct DeleteResponse: Decodable {
    var ok: Bool
}

private struct APIErrorResponse: Decodable {
    var error: String
    var requestId: String?
}

private struct PublishSpellBody: Encodable {
    var uid: String?
    var name: String
    var description: String
    var trigger: String
    var tags: [String]
    var file: String
    var content: String

    init(spell: Spell) {
        uid = spell.uid
        name = spell.name
        description = spell.description
        trigger = spell.trigger
        tags = spell.tags
        file = spell.file
        content = spell.content ?? ""
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
