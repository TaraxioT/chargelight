import ChargeLight
import Foundation

/// A JSON value, encoded with sorted keys for stable output.
enum JSON: Encodable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .uint(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// One line of compact JSON with sorted keys.
    var serialized: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{\"ok\":false}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func string(_ value: String?) -> JSON {
        value.map(JSON.string) ?? .null
    }

    static func date(_ date: Date) -> JSON {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return .string(formatter.string(from: date))
    }

    static func override(_ override: Override?) -> JSON {
        guard let override else { return .null }
        return .object([
            "led": .string(override.led.rawValue),
            "setAt": .date(override.setAt),
            "expiresAt": override.expiresAt.map(JSON.date) ?? .null,
        ])
    }

    static func claim(_ claim: Claim, configuration: Configuration) -> JSON {
        .object([
            "id": .string(claim.id),
            "status": .string(claim.status.rawValue),
            "label": .string(claim.label),
            "led": .string(configuration.led(for: claim.status).rawValue),
            "updatedAt": .date(claim.updatedAt),
            "expiresAt": .date(claim.expiresAt),
            "stamp": .uint(claim.stamp),
        ])
    }
}
