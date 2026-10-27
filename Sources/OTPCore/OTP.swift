import Foundation
import CryptoKit

public enum OTPAlgorithm: String, Codable, CaseIterable, Identifiable, Sendable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    public var id: String { rawValue }
}

public enum OTPError: LocalizedError, Equatable {
    case invalidURI
    case unsupportedType(String)
    case invalidSecret
    case invalidMigrationData
    case noAccountsFound

    public var errorDescription: String? {
        switch self {
        case .invalidURI: return String(localized: "无法识别的链接，需要 otpauth:// 或 otpauth-migration:// 格式")
        case .unsupportedType(let t): return String(localized: "暂不支持 \(t.uppercased()) 类型，仅支持 TOTP")
        case .invalidSecret: return String(localized: "密钥无效（需要 Base32 编码）")
        case .invalidMigrationData: return String(localized: "Google 身份验证器导出数据无法解析")
        case .noAccountsFound: return String(localized: "没有找到可导入的账户")
        }
    }
}

// MARK: - Base32 (RFC 4648)

public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let lookup: [Character: UInt8] = {
        var map = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        return map
    }()

    /// Normalizes user input: uppercases and strips spaces, dashes and padding.
    public static func normalize(_ string: String) -> String {
        string.uppercased().filter { !$0.isWhitespace && $0 != "=" && $0 != "-" }
    }

    public static func decode(_ string: String) -> Data? {
        let cleaned = normalize(string)
        guard !cleaned.isEmpty else { return nil }
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for c in cleaned {
            guard let v = lookup[c] else { return nil }
            buffer = ((buffer << 5) | UInt32(v)) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out.isEmpty ? nil : out
    }

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = ((buffer << 8) | UInt32(byte)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return out
    }
}

// MARK: - HOTP / TOTP (RFC 4226 / RFC 6238)

public enum OTPGenerator {
    public static func hotp(key: Data, counter: UInt64, digits: Int, algorithm: OTPAlgorithm) -> String {
        var big = counter.bigEndian
        let message = Data(bytes: &big, count: MemoryLayout<UInt64>.size)
        let symmetricKey = SymmetricKey(data: key)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetricKey))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetricKey))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset]) & 0x7F) << 24
            | UInt32(mac[offset + 1]) << 16
            | UInt32(mac[offset + 2]) << 8
            | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: max(0, digits - value.count)) + value
    }

    public static func totp(key: Data, date: Date, period: Int, digits: Int, algorithm: OTPAlgorithm) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(period))
        return hotp(key: key, counter: counter, digits: digits, algorithm: algorithm)
    }
}

// MARK: - Account

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var issuer: String
    public var name: String
    public var secret: String
    public var digits: Int
    public var period: Int
    public var algorithm: OTPAlgorithm
    /// Hidden accounts are kept but not shown in the menu bar panel.
    public var hidden: Bool

    public init(id: UUID = UUID(), issuer: String, name: String, secret: String,
                digits: Int = 6, period: Int = 30, algorithm: OTPAlgorithm = .sha1, hidden: Bool = false) {
        self.id = id
        self.issuer = issuer
        self.name = name
        self.secret = Base32.normalize(secret)
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, issuer, name, secret, digits, period, algorithm, hidden
    }

    // Custom decoding so data saved before `hidden` existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        issuer = try c.decode(String.self, forKey: .issuer)
        name = try c.decode(String.self, forKey: .name)
        secret = try c.decode(String.self, forKey: .secret)
        digits = try c.decode(Int.self, forKey: .digits)
        period = try c.decode(Int.self, forKey: .period)
        algorithm = try c.decode(OTPAlgorithm.self, forKey: .algorithm)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    public var title: String { issuer.isEmpty ? (name.isEmpty ? String(localized: "未命名") : name) : issuer }
    public var subtitle: String { issuer.isEmpty ? "" : name }

    public func code(at date: Date = Date()) -> String? {
        guard let key = Base32.decode(secret) else { return nil }
        return OTPGenerator.totp(key: key, date: date, period: period, digits: digits, algorithm: algorithm)
    }

    public func secondsRemaining(at date: Date = Date()) -> Double {
        let p = Double(period)
        return p - date.timeIntervalSince1970.truncatingRemainder(dividingBy: p)
    }

    public var otpauthURL: String {
        var comps = URLComponents()
        comps.scheme = "otpauth"
        comps.host = "totp"
        comps.path = "/" + (issuer.isEmpty ? name : "\(issuer):\(name)")
        var items = [URLQueryItem(name: "secret", value: secret)]
        if !issuer.isEmpty { items.append(URLQueryItem(name: "issuer", value: issuer)) }
        items.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue))
        items.append(URLQueryItem(name: "digits", value: String(digits)))
        items.append(URLQueryItem(name: "period", value: String(period)))
        comps.queryItems = items
        return comps.string ?? ""
    }
}

// MARK: - Import

public enum AccountImporter {
    /// Parses one or more otpauth:// / otpauth-migration:// links (one per line or whitespace separated).
    public static func parse(_ text: String) throws -> [Account] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { $0.lowercased().hasPrefix("otpauth") }
        guard !tokens.isEmpty else { throw OTPError.invalidURI }
        var result: [Account] = []
        var firstError: Error?
        for token in tokens {
            do {
                if token.lowercased().hasPrefix("otpauth-migration://") {
                    result += try parseMigration(token)
                } else {
                    result.append(try parseURI(token))
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if result.isEmpty { throw firstError ?? OTPError.noAccountsFound }
        return result
    }

    public static func parseURI(_ string: String) throws -> Account {
        guard let comps = URLComponents(string: string),
              comps.scheme?.lowercased() == "otpauth",
              let type = comps.host?.lowercased() else { throw OTPError.invalidURI }
        guard type == "totp" else { throw OTPError.unsupportedType(type) }

        var label = comps.path
        if label.hasPrefix("/") { label.removeFirst() }
        var issuer = ""
        var name = label
        if let colon = label.firstIndex(of: ":") {
            issuer = label[..<colon].trimmingCharacters(in: .whitespaces)
            name = label[label.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] where query[item.name.lowercased()] == nil {
            query[item.name.lowercased()] = item.value ?? ""
        }
        guard let secret = query["secret"], Base32.decode(secret) != nil else { throw OTPError.invalidSecret }
        if let i = query["issuer"], !i.isEmpty { issuer = i }
        let digits = Int(query["digits"] ?? "").flatMap { (6...8).contains($0) ? $0 : nil } ?? 6
        let period = Int(query["period"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 30
        let algorithm = OTPAlgorithm(rawValue: (query["algorithm"] ?? "SHA1").uppercased()) ?? .sha1
        return Account(issuer: issuer, name: name, secret: secret, digits: digits, period: period, algorithm: algorithm)
    }

    /// Google Authenticator "Transfer accounts" export (protobuf MigrationPayload).
    public static func parseMigration(_ string: String) throws -> [Account] {
        guard let comps = URLComponents(string: string),
              var b64 = comps.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw OTPError.invalidMigrationData
        }
        b64 = b64.replacingOccurrences(of: " ", with: "+")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { throw OTPError.invalidMigrationData }

        var accounts: [Account] = []
        var reader = ProtoReader(data)
        while let (field, wire) = try reader.nextKey() {
            if field == 1 && wire == 2 {
                if let account = try parseOtpParameters(try reader.lengthDelimited()) {
                    accounts.append(account)
                }
            } else {
                try reader.skip(wire: wire)
            }
        }
        if accounts.isEmpty { throw OTPError.noAccountsFound }
        return accounts
    }

    private static func parseOtpParameters(_ bytes: [UInt8]) throws -> Account? {
        var reader = ProtoReader(Data(bytes))
        var secret = Data(), name = "", issuer = ""
        var algorithm = OTPAlgorithm.sha1, digits = 6, isTOTP = true
        while let (field, wire) = try reader.nextKey() {
            switch (field, wire) {
            case (1, 2): secret = Data(try reader.lengthDelimited())
            case (2, 2): name = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (3, 2): issuer = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (4, 0):
                switch try reader.varint() {
                case 2: algorithm = .sha256
                case 3: algorithm = .sha512
                default: algorithm = .sha1
                }
            case (5, 0): digits = try reader.varint() == 2 ? 8 : 6
            case (6, 0): isTOTP = try reader.varint() != 1
            default: try reader.skip(wire: wire)
            }
        }
        guard isTOTP, !secret.isEmpty else { return nil }
        // Labels in exports are often "Issuer:account".
        if let colon = name.firstIndex(of: ":") {
            let prefix = name[..<colon].trimmingCharacters(in: .whitespaces)
            if issuer.isEmpty || issuer == prefix {
                issuer = prefix
                name = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return Account(issuer: issuer, name: name, secret: Base32.encode(secret), digits: digits, algorithm: algorithm)
    }
}

private struct ProtoReader {
    let bytes: [UInt8]
    var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw OTPError.invalidMigrationData }
            let b = bytes[index]
            index += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func nextKey() throws -> (Int, Int)? {
        guard index < bytes.count else { return nil }
        let key = try varint()
        return (Int(key >> 3), Int(key & 0x7))
    }

    mutating func lengthDelimited() throws -> [UInt8] {
        let length = Int(try varint())
        guard length >= 0, index + length <= bytes.count else { throw OTPError.invalidMigrationData }
        defer { index += length }
        return Array(bytes[index..<index + length])
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: index += 8
        case 2: _ = try lengthDelimited()
        case 5: index += 4
        default: throw OTPError.invalidMigrationData
        }
        if index > bytes.count { throw OTPError.invalidMigrationData }
    }
}
