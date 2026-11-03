import Foundation

/// The kinds of objects Dabble stores.
public enum Kind: String, Codable, Sendable, CaseIterable {
    case area
    case project
    case heading
    case todo
    case tag
    case checklist
}

/// A JSON-like value stored in a record field.
public enum Value: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([String])
}

extension Value: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String].self) {
            self = .list(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        }
    }
}

/// One last-writer-wins register.
public struct Field: Codable, Hashable, Sendable {
    public var v: Value
    public var t: HLC

    public init(_ value: Value, _ timestamp: HLC) {
        v = value
        t = timestamp
    }
}

/// A replicated object: a bag of independently versioned fields.
///
/// Records form a state-based CRDT. Merging two copies keeps, per field, the
/// value with the greatest timestamp. Merging is commutative, associative and
/// idempotent, so devices can exchange records in any order, any number of
/// times, through any path, and still converge.
public struct Record: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: Kind
    public var fields: [String: Field]
    /// Local sequence number of the last change to this record on this device.
    /// Used to find what a peer has not seen yet; meaningless across devices.
    public var seq: Int64

    public init(id: UUID, kind: Kind, fields: [String: Field] = [:], seq: Int64 = 0) {
        self.id = id
        self.kind = kind
        self.fields = fields
        self.seq = seq
    }

    public var values: [String: Value] { fields.mapValues(\.v) }

    /// Most recent write to any field.
    public var modified: HLC { fields.values.map(\.t).max() ?? .zero }

    /// Merges `other` into this record. Returns true if anything changed.
    @discardableResult
    public mutating func merge(_ other: Record) -> Bool {
        var changed = false
        for (key, theirs) in other.fields {
            if let mine = fields[key], mine.t >= theirs.t { continue }
            fields[key] = theirs
            changed = true
        }
        return changed
    }
}
