import AppKit
import CoreImage
import Security
import SwiftUI

// MARK: - Keychain

enum Keychain {
    private static let service = "local.otpbar.accounts"
    private static let account = "accounts"

    enum ReadResult { case found(Data), notFound, failed(OSStatus) }

    static func read() -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return .found(item as? Data ?? Data())
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    @discardableResult
    static func write(_ data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = String(localized: "OTPBar 验证码账户")
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Store

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    /// Transient message shown at the top of the list (import results, errors).
    @Published var banner: Banner?

    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    /// Set when the keychain could not be read, so we never overwrite existing data with an empty list.
    private var readOnly = false

    init() { load() }

    func load() {
        switch Keychain.read() {
        case .found(let data):
            do {
                accounts = try JSONDecoder().decode([Account].self, from: data)
                readOnly = false
            } catch {
                readOnly = true
                show(String(localized: "钥匙串数据无法解析，已暂停保存以免覆盖"), error: true)
            }
        case .notFound:
            accounts = []
            readOnly = false
        case .failed(let status):
            readOnly = true
            show(String(localized: "读取钥匙串失败（\(Int(status))），请在弹窗中允许访问后重试"), error: true)
        }
    }

    private func save() {
        guard !readOnly else {
            show(String(localized: "钥匙串不可用，修改未保存"), error: true)
            return
        }
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        let status = Keychain.write(data)
        if status != errSecSuccess { show(String(localized: "保存到钥匙串失败（\(Int(status))）"), error: true) }
    }

    /// Adds accounts, skipping exact duplicates (same secret + name). Returns the number added.
    @discardableResult
    func add(_ new: [Account]) -> Int {
        var added = 0
        for account in new where !accounts.contains(where: { $0.secret == account.secret && $0.name == account.name }) {
            accounts.append(account)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func update(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        save()
    }

    func delete(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setHidden(_ account: Account, _ hidden: Bool) {
        var changed = account
        changed.hidden = hidden
        update(changed)
    }

    /// Imports from text containing otpauth links and reports the outcome in the banner.
    @discardableResult
    func importText(_ text: String) -> Banner {
        do {
            let parsed = try AccountImporter.parse(text)
            return report(added: add(parsed), total: parsed.count)
        } catch {
            return show(error.localizedDescription, error: true)
        }
    }

    @discardableResult
    func report(added: Int, total: Int) -> Banner {
        if added == 0 {
            return show(String(localized: "账户已存在，未重复添加"), error: true)
        } else if added == total {
            return show(String(localized: "已添加 \(added) 个账户"), error: false)
        } else {
            return show(String(localized: "已添加 \(added) 个账户，跳过 \(total - added) 个重复项"), error: false)
        }
    }

    @discardableResult
    func show(_ text: String, error: Bool) -> Banner {
        let banner = Banner(text: text, isError: error)
        self.banner = banner
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.banner == banner { self?.banner = nil }
        }
        return banner
    }
}

// MARK: - Clipboard

enum Clipboard {
    /// Marker type respected by clipboard managers (Maccy, Raycast, Alfred…) to skip recording.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ string: String, clearAfter seconds: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        pb.setString("", forType: concealed)
        guard seconds > 0 else { return }
        let change = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            // Only clear if the user hasn't copied something else since.
            if pb.changeCount == change { pb.clearContents() }
        }
    }
}

// MARK: - QR code

enum QRScanner {
    static func decode(_ image: NSImage) -> [String] {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return [] }
        return decode(ci)
    }

    static func decode(_ image: CIImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: image) ?? [])
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    /// Lets the user drag-select a screen region with the system screenshot tool, then decodes QR codes in it.
    static func captureScreenRegion(completion: @escaping @MainActor ([String]?) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otpbar-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { _ in
            defer { try? FileManager.default.removeItem(at: url) }
            // nil = user cancelled (no file written).
            let result: [String]? = NSImage(contentsOf: url).map { decode($0) }
            DispatchQueue.main.async { completion(result) }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { completion([]) }
        }
    }
}
