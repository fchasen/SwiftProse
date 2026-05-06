import Foundation

public struct PMNode: Codable, Sendable, Equatable {
    public var type: String
    public var attrs: [String: PMValue]?
    public var content: [PMNode]?
    public var text: String?
    public var marks: [PMMark]?

    public init(
        type: String,
        attrs: [String: PMValue]? = nil,
        content: [PMNode]? = nil,
        text: String? = nil,
        marks: [PMMark]? = nil
    ) {
        self.type = type
        self.attrs = attrs
        self.content = content
        self.text = text
        self.marks = marks
    }
}

public struct PMMark: Codable, Sendable, Equatable {
    public var type: String
    public var attrs: [String: PMValue]?

    public init(type: String, attrs: [String: PMValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }
}

public indirect enum PMValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([PMValue])
    case object([String: PMValue])

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        if case .double(let v) = self { return Int(v) }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    public var arrayValue: [PMValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    public var objectValue: [String: PMValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([PMValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: PMValue].self) { self = .object(v) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
