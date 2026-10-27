import Foundation

var failures = 0
func check(_ label: String, _ got: String?, _ expected: String) {
    if got == expected {
        print("✓ \(label)")
    } else {
        print("✗ \(label): got \(got ?? "nil"), expected \(expected)")
        failures += 1
    }
}

// RFC 6238 Appendix B test vectors (8 digits).
let seeds: [(OTPAlgorithm, String)] = [
    (.sha1, "12345678901234567890"),
    (.sha256, "12345678901234567890123456789012"),
    (.sha512, "1234567890123456789012345678901234567890123456789012345678901234"),
]
let vectors: [(TimeInterval, [String])] = [
    (59, ["94287082", "46119246", "90693936"]),
    (1111111109, ["07081804", "68084774", "25091201"]),
    (1234567890, ["89005924", "91819424", "93441116"]),
    (20000000000, ["65353130", "77737706", "47863826"]),
]
for (time, expected) in vectors {
    for (i, (alg, seed)) in seeds.enumerated() {
        let code = OTPGenerator.totp(key: Data(seed.utf8), date: Date(timeIntervalSince1970: time),
                                     period: 30, digits: 8, algorithm: alg)
        check("RFC6238 \(alg.rawValue) t=\(Int(time))", code, expected[i])
    }
}

// Base32 round trip.
let raw = Data("12345678901234567890".utf8)
let encoded = Base32.encode(raw)
check("Base32 encode", encoded, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
check("Base32 decode", Base32.decode("gezd gnbv gy3t qojq gezd gnbv gy3t qojq").map { String(decoding: $0, as: UTF8.self) },
      "12345678901234567890")

// otpauth URI parsing.
do {
    let a = try AccountImporter.parseURI("otpauth://totp/ACME%20Co:john@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=ACME%20Co&digits=8&algorithm=SHA256")
    check("URI issuer", a.issuer, "ACME Co")
    check("URI name", a.name, "john@example.com")
    check("URI digits", String(a.digits), "8")
    check("URI algorithm", a.algorithm.rawValue, "SHA256")
    let b = try AccountImporter.parseURI(a.otpauthURL)
    check("URI round trip", b.secret + b.issuer + b.name, a.secret + a.issuer + a.name)
} catch {
    print("✗ URI parse threw \(error)"); failures += 1
}

// Google Authenticator migration payload: one TOTP account, secret "Hello!" + 0xDEADBEEF, name "test@example.com", issuer "Example".
do {
    var payload = Data()
    var params = Data()
    let secret: [UInt8] = Array("Hello!".utf8) + [0xDE, 0xAD, 0xBE, 0xEF]
    params.append(contentsOf: [0x0A, UInt8(secret.count)] + secret)
    let name = Array("Example:test@example.com".utf8)
    params.append(contentsOf: [0x12, UInt8(name.count)] + name)
    let issuer = Array("Example".utf8)
    params.append(contentsOf: [0x1A, UInt8(issuer.count)] + issuer)
    params.append(contentsOf: [0x20, 0x01, 0x28, 0x01, 0x30, 0x02])
    payload.append(contentsOf: [0x0A, UInt8(params.count)])
    payload.append(params)
    payload.append(contentsOf: [0x10, 0x01]) // version
    let b64 = payload.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    let accounts = try AccountImporter.parse("otpauth-migration://offline?data=\(b64)")
    check("Migration count", String(accounts.count), "1")
    check("Migration issuer", accounts.first?.issuer, "Example")
    check("Migration name", accounts.first?.name, "test@example.com")
    check("Migration secret", accounts.first?.secret, Base32.encode(Data(secret)))
} catch {
    print("✗ Migration parse threw \(error)"); failures += 1
}

// Accounts saved before the `hidden` field existed must still decode.
do {
    let legacy = #"[{"id":"6F1C2A8E-2B1D-4C1E-9C2B-1A2B3C4D5E6F","issuer":"A","name":"b","secret":"GEZDGNBV","digits":6,"period":30,"algorithm":"SHA1"}]"#
    let decoded = try JSONDecoder().decode([Account].self, from: Data(legacy.utf8))
    check("Legacy decode hidden=false", String(decoded.first?.hidden ?? true), "false")
    var hidden = decoded[0]
    hidden.hidden = true
    let roundTrip = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(hidden))
    check("Hidden round trip", String(roundTrip.hidden), "true")
} catch {
    print("✗ Legacy decode threw \(error)"); failures += 1
}

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
