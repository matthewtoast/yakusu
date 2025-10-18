import Foundation

struct TranslationService {
    private let client: APIClient

    init(baseURL: URL, session: URLSession = .shared, tokenProvider: @escaping () -> String? = { nil }) {
        client = APIClient(baseURL: baseURL, session: session, tokenProvider: tokenProvider)
    }

    func translate(text: String, sl: LangLocale, tl: LangLocale, instruction: String) async -> String? {
        let trimmedHint = String(instruction.prefix(100))
        let payload = TranslationPayload(
            text: text,
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
        let trimmed = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return trimmed
    }
}

private struct TranslationPayload: Encodable {
    let text: String
    let sl: String
    let tl: String
    let instruction: String
}

private struct TranslationResponse: Decodable {
    let ok: Bool
    let text: String

    private enum CodingKeys: String, CodingKey {
        case ok
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
    }
}
