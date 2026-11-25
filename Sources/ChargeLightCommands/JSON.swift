import ChargeLight
import Foundation

/// A JSON value, encoded with sorted keys for stable output.
enum JSON: Encodable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
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
        case .double(let value): try container.encode(value)
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

    /// Seconds, rounded to the millisecond so `3 * 0.3` prints as `0.9`.
    static func seconds(_ value: TimeInterval) -> JSON {
        .double((value * 1000).rounded() / 1000)
    }

    static func error(_ error: ChargeLightError) -> JSON {
        .object([
            "ok": .bool(false),
            "error": .object(["code": .string(error.code), "message": .string(error.message)]),
        ])
    }

    static func override(_ override: Override?) -> JSON {
        guard let override else { return .null }
        return .object([
            "show": .string(override.show),
            "setAt": .date(override.setAt),
            "expiresAt": override.expiresAt.map(JSON.date) ?? .null,
        ])
    }

    /// A claim; `led` is what its `show` resolves to now, or null if it no longer does.
    static func claim(_ claim: Claim, configuration: Configuration) -> JSON {
        .object([
            "id": .string(claim.id),
            "show": .string(claim.show),
            "led": .string((try? configuration.resolve(claim.show))?.description),
            "priority": .int(Int64(claim.priority)),
            "label": .string(claim.label),
            "updatedAt": .date(claim.updatedAt),
            "expiresAt": .date(claim.expiresAt),
            "stamp": .uint(claim.stamp),
        ])
    }
}
