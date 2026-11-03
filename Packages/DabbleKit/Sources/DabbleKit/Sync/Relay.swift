import CryptoKit
import Foundation

/// Keys for the optional sync server, all derived from the sync group key.
///
/// The server sees a group id and a bearer token (both one-way derivations,
/// so neither reveals the group key), an opaque key per row, the row's HLC
/// timestamp and ciphertext. To-do contents never leave the device unencrypted.
struct RelayKeys: Sendable {
    let groupID: String
    let token: String
    private let sealKey: SymmetricKey
    private let rowKeyKey: SymmetricKey

    init(groupKey: Data) {
        func derive(_ info: String, _ bytes: Int) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: groupKey), salt: Data("dabble-relay-v1".utf8),
                                   info: Data(info.utf8), outputByteCount: bytes)
        }
        func hex(_ key: SymmetricKey) -> String {
            key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        }
        groupID = hex(derive("group-id", 16))
        token = hex(derive("token", 32))
        sealKey = derive("seal", 32)
        rowKeyKey = derive("row-key", 32)
    }

    /// Stable per-field identifier the server uses to keep only the latest row.
    func rowKey(_ id: UUID, _ field: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(id.uuidString)|\(field)".utf8), using: rowKeyKey)
        return mac.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func seal(_ plaintext: Data) throws -> String {
        try ChaChaPoly.seal(plaintext, using: sealKey).combined.base64EncodedString()
    }

    func open(_ sealed: String) -> Data? {
        guard let data = Data(base64Encoded: sealed), let box = try? ChaChaPoly.SealedBox(combined: data) else { return nil }
        return try? ChaChaPoly.open(box, using: sealKey)
    }
}

extension HLC {
    /// Fixed-width form that sorts the same way HLCs compare, so the server can
    /// pick the latest row with a plain string comparison.
    var sortable: String {
        String(format: "%015lld-%010d-", wall, counter) + node
    }
}

/// HTTP client for the relay in `server/`.
struct RelayClient: Sendable {
    let baseURL: URL
    let keys: RelayKeys
    let session: URLSession

    struct ServerError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? {
            switch status {
            case 401, 403: "The sync server refused this device (\(message))."
            default: "Sync server error \(status): \(message)"
            }
        }
    }

    private struct Row: Codable { var k: String; var h: String; var d: String }
    private struct PushBody: Codable { var rows: [Row] }
    private struct PushResponse: Codable { var accepted: Int; var cursor: Int }
    private struct PullResponse: Codable { var rows: [String]; var cursor: Int; var more: Bool }

    init(baseURL: URL, keys: RelayKeys, session: URLSession = RelayClient.makeSession()) {
        self.baseURL = baseURL
        self.keys = keys
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    private func endpoint(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/groups/\(keys.groupID)/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func request(_ url: URL, method: String, body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(keys.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerError(status: 0, message: "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw ServerError(status: http.statusCode, message: message)
        }
    }

    func health() async throws {
        let (data, response) = try await session.data(for: request(baseURL.appendingPathComponent("v1/health"), method: "GET", timeout: 10))
        try check(response, data)
        guard (try? JSONDecoder().decode([String: AnyCodableValue].self, from: data))?["service"] == .string("dabble-sync") else {
            throw ServerError(status: 0, message: "That address isn't a Dabble sync server.")
        }
    }

    /// Uploads every field of the given records. Returns the server's cursor.
    @discardableResult
    func push(_ records: [Record]) async throws -> Int {
        var rows: [Row] = []
        let encoder = JSONEncoder()
        for record in records {
            for (key, field) in record.fields {
                let single = Record(id: record.id, kind: record.kind, fields: [key: field])
                rows.append(Row(k: keys.rowKey(record.id, key), h: field.t.sortable, d: try keys.seal(encoder.encode(single))))
            }
        }
        var cursor = 0
        for start in stride(from: 0, to: max(rows.count, 1), by: 2_000) {
            let chunk = Array(rows[start..<min(start + 2_000, rows.count)])
            let body = try encoder.encode(PushBody(rows: chunk))
            let (data, response) = try await session.data(for: request(endpoint("push"), method: "POST", body: body, timeout: 60))
            try check(response, data)
            cursor = try JSONDecoder().decode(PushResponse.self, from: data).cursor
        }
        return cursor
    }

    /// Fetches rows after `cursor`, waiting up to `wait` seconds for new ones.
    func pull(since cursor: Int, wait: Int, limit: Int = 1_000) async throws -> (records: [Record], cursor: Int, more: Bool) {
        let url = endpoint("pull", [.init(name: "since", value: String(cursor)), .init(name: "limit", value: String(limit)), .init(name: "wait", value: String(wait))])
        let (data, response) = try await session.data(for: request(url, method: "GET", timeout: TimeInterval(wait + 20)))
        try check(response, data)
        let decoded = try JSONDecoder().decode(PullResponse.self, from: data)
        let decoder = JSONDecoder()
        // Rows that don't decrypt (e.g. from a different group sharing a token by accident) are skipped.
        let records = decoded.rows.compactMap { keys.open($0).flatMap { try? decoder.decode(Record.self, from: $0) } }
        return (records, decoded.cursor, decoded.more)
    }
}

/// Just enough of JSON to read `{"service": "dabble-sync", "ok": true, ...}`.
enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { self = .string(string) } else { self = .other }
    }

    func encode(to encoder: Encoder) throws {}
}
