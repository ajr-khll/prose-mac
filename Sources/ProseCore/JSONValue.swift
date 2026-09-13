import Foundation

/// Any JSON value, decoded without knowing what it is yet.
///
/// This type exists to serve one rule, spec §10's most important one: *an
/// unknown method, an unknown event kind, or a malformed line is ignored, never
/// an error*. `Codable`'s whole design is to throw when a document does not
/// match a type, which fights that rule — and scattering `try?` over a tree of
/// `Codable` structs to suppress it hides real decoding failures along with the
/// intended ones.
///
/// So the line is decoded exactly once, into this, and every question asked of
/// it afterwards returns `nil` rather than throwing (see `Protocol.swift`).
/// plan §5: one `try?` at the line boundary, everything below it total.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Integers are kept apart from doubles so a JSON-RPC id, a session number
    /// or an error code survives a round trip as the integer it was written as.
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {
    /// A member of an object, or `nil` for a missing key *or* a value that is
    /// not an object at all — the caller cannot tell the two apart and, under
    /// the ignore-don't-fail rule, never needs to.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    /// Reads whatever a JavaScript evaluation handed back.
    ///
    /// `evaluateJavaScript` answers with `Any?` — `NSNull`, `NSNumber`,
    /// `NSString`, `NSArray`, `NSDictionary` — and a page can return something
    /// none of those cover. **Total, like everything else that faces an
    /// agent**: anything unrepresentable becomes `null` rather than throwing,
    /// because a value prose cannot describe is still a call that finished.
    ///
    /// `NSNumber` is the awkward one: it does not say whether it was written as
    /// a boolean, so its ObjC type encoding is what separates `true` from `1`.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null

        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if String(cString: number.objCType) == "d"
                || String(cString: number.objCType) == "f"
            {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }

        case let text as String:
            self = .string(text)

        case let items as [Any]:
            self = .array(items.map { JSONValue(any: $0) })

        case let fields as [String: Any]:
            self = .object(fields.mapValues { JSONValue(any: $0) })

        default:
            self = .null
        }
    }

    public var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var int: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    /// Either numeric case, as a `Double`.
    ///
    /// JavaScript has one number type, so **everything** that crosses the
    /// WebKit bridge arrives as a `Double` — a page reporting three hundred
    /// elements reads as `.double(300)` and `int` answers `nil` for it. Wire
    /// traffic, parsed from JSON text, keeps whole numbers as `.int`. Reading
    /// a count from either side otherwise means knowing which side it came
    /// from, which is exactly the kind of thing a caller gets wrong once and
    /// then cannot see.
    public var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// Session and pane ids are unsigned on the wire. A negative one is not a
    /// smaller id, it is a malformed line, so it reads as `nil`.
    public var unsigned: UInt64? {
        guard let value = int, value >= 0 else { return nil }
        return UInt64(value)
    }

    public var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var object: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// An array of strings, or `nil` if any element is something else. All or
    /// nothing, because a half-read command line would be worse than none.
    public var stringArray: [String]? {
        guard let array else { return nil }
        var out: [String] = []
        out.reserveCapacity(array.count)
        for element in array {
            guard let string = element.string else { return nil }
            out.append(string)
        }
        return out
    }

    /// An object whose values are all strings, or `nil` otherwise.
    public var stringMap: [String: String]? {
        guard let object else { return nil }
        var out: [String: String] = [:]
        out.reserveCapacity(object.count)
        for (key, value) in object {
            guard let string = value.string else { return nil }
            out[key] = string
        }
        return out
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Ordered narrowest-first: a JSON `true` must not come back as a number
        // and an integer must not come back as a double, or ids stop round
        // tripping.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not JSON this build can represent"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Writing a line

extension JSONValue {
    /// One line of JSON, without its newline.
    ///
    /// Keys are sorted so a line is reproducible run to run, which matters for
    /// reading a log; JSON-RPC itself does not care about member order. An
    /// encoder failure is impossible for a value already known to be JSON, so
    /// the fallback is an empty object rather than a `try` the callers would
    /// have to carry up.
    public func line() -> String {
        let encoder = JSONEncoder()
        // A URL in an attachment should read as a URL, not as `http:\/\/`.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
