import Foundation

/// A hybrid logical clock timestamp.
///
/// Every field write in Dabble is stamped with an HLC. When two devices edit the
/// same field concurrently, the write with the greater timestamp wins. Ties on
/// wall time and counter are broken by node id, so every device converges on
/// the same answer without coordination.
public struct HLC: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var wall: Int64
    public var counter: Int32
    public var node: String

    public init(wall: Int64, counter: Int32, node: String) {
        self.wall = wall
        self.counter = counter
        self.node = node
    }

    public static let zero = HLC(wall: 0, counter: 0, node: "")

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        if lhs.wall != rhs.wall { return lhs.wall < rhs.wall }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.node < rhs.node
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(wall) / 1000) }

    public var description: String { "\(wall).\(counter).\(node)" }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let wall = Int64(parts[0]), let counter = Int32(parts[1]) else { return nil }
        self.init(wall: wall, counter: counter, node: String(parts[2]))
    }
}

extension HLC: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = HLC(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid HLC \(string)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Generates monotonically increasing HLC timestamps for one device.
public struct HybridClock: Sendable {
    public private(set) var last: HLC
    public let node: String
    var physicalTime: @Sendable () -> Int64

    public init(node: String, last: HLC = .zero, physicalTime: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.node = node
        self.last = HLC(wall: last.wall, counter: last.counter, node: node)
        self.physicalTime = physicalTime
    }

    public mutating func now() -> HLC {
        let physical = physicalTime()
        if physical > last.wall {
            last = HLC(wall: physical, counter: 0, node: node)
        } else {
            last = HLC(wall: last.wall, counter: last.counter + 1, node: node)
        }
        return last
    }

    /// Advances the clock past a timestamp received from another device so that
    /// local writes made afterwards always win over what we have already seen.
    public mutating func observe(_ remote: HLC) {
        if remote.wall > last.wall || (remote.wall == last.wall && remote.counter > last.counter) {
            last = HLC(wall: remote.wall, counter: remote.counter, node: node)
        }
    }
}
