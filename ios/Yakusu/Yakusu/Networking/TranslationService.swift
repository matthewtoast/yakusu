import Foundation

struct TranslationService {
    private let client: APIClient

    init(baseURL: URL, session: URLSession = .shared, tokenProvider: @escaping () -> String? = { nil }) {
        client = APIClient(baseURL: baseURL, session: session, tokenProvider: tokenProvider)
    }

    func translate(lines: [String], sl: LangLocale, tl: LangLocale, instruction: String) async -> [String]? {
        let trimmedHint = String(instruction.prefix(100))
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned.isEmpty {
            return nil
        }
        let payload = TranslationPayload(
            lines: cleaned,
            sl: langLocaleToString(sl),
            tl: langLocaleToString(tl),
            instruction: trimmedHint
        )
        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(payload) else {
            return nil
        }
        let response: TranslationResponse? = try? await client.request(
            method: "POST",
            path: "api/translate",
            body: body
        )
        guard let res = response else {
            return nil
        }
        if !res.ok {
            return nil
        }
        if res.lines.count != cleaned.count {
            return nil
        }
        return res.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private struct TranslationPayload: Encodable {
    let lines: [String]
    let sl: String
    let tl: String
    let instruction: String
}

private struct TranslationResponse: Decodable {
    let ok: Bool
    let lines: [String]

    private enum CodingKeys: String, CodingKey {
        case ok
        case lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        lines = (try? container.decode([String].self, forKey: .lines)) ?? []
    }
}
