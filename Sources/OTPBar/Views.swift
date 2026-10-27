import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum WindowID {
    static let add = "add"
    static let edit = "edit"
    static let settings = "settings"
}

enum Prefs {
    static let clearClipboard = "clearClipboardSeconds"
    static let closeAfterCopy = "closeAfterCopy"
    static let groupDigits = "groupDigits"
    static let settingsTab = "settingsTab"
    static let language = "appLanguage"
}

@MainActor func confirmDelete(_ account: Account, from store: AccountStore) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = String(localized: "删除“\(account.title)”？")
    alert.informativeText = String(localized: "删除后将无法再生成该账户的验证码。请确认你已在对应网站关闭两步验证或有其他备份。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "删除")).hasDestructiveAction = true
    alert.addButton(withTitle: String(localized: "取消"))
    if alert.runModal() == .alertFirstButtonReturn { store.delete(account) }
}

func formatCode(_ code: String, grouped: Bool) -> String {
    guard grouped, code.count >= 6 else { return code }
    let mid = code.index(code.startIndex, offsetBy: code.count / 2)
    return code[..<mid] + " " + code[mid...]
}

// MARK: - Regular windows

/// The app normally lives only in the menu bar (LSUIElement). While any regular window is open it
/// becomes a normal app — Dock icon, ⌘Tab, main menu — so the window behaves like ordinary software.
@MainActor
enum AppPresence {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

extension View {
    func regularWindow() -> some View {
        onAppear { AppPresence.windowOpened() }
            .onDisappear { AppPresence.windowClosed() }
    }
}

extension OpenWindowAction {
    /// Opens (or brings forward) a window and activates the app so it lands in front.
    @MainActor func show(id: String) {
        self(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func show<D: Codable & Hashable>(id: String, value: D) {
        self(id: id, value: value)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Menu bar panel

struct AccountListView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var copiedID: UUID?
    @FocusState private var searchFocused: Bool
    @AppStorage(Prefs.clearClipboard) private var clearAfter = 60
    @AppStorage(Prefs.closeAfterCopy) private var closeAfterCopy = true
    @AppStorage(Prefs.groupDigits) private var groupDigits = true
    @AppStorage(Prefs.settingsTab) private var settingsTab = SettingsTab.accounts

    private var visible: [Account] { store.accounts.filter { !$0.hidden } }

    private var filtered: [Account] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return visible }
        return visible.filter { $0.issuer.lowercased().contains(q) || $0.name.lowercased().contains(q) }
    }

    /// The period most accounts use; it drives the shared countdown bar.
    private var sharedPeriod: Int {
        let counts = Dictionary(grouping: visible, by: \.period).mapValues(\.count)
        return counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? 30
    }

    var body: some View {
        // Ticks on whole seconds so codes and cells change exactly at period boundaries.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { context in
            VStack(spacing: 0) {
                header
                if let banner = store.banner { BannerView(banner: banner).padding(.horizontal, 12).padding(.bottom, 8) }
                if visible.isEmpty {
                    Divider()
                    emptyState
                } else {
                    CountdownBar(date: context.date, period: sharedPeriod)
                    if filtered.isEmpty {
                        Text("没有匹配“\(query)”的账户")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        list(at: context.date)
                    }
                }
                Divider()
                footer
            }
        }
        .frame(width: 360)
        .background(shortcuts)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = filtered.first { copy(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            IconButton(systemName: "plus", help: "添加账户 (⌘N)") { openWindow.show(id: WindowID.add) }
                .keyboardShortcut("n", modifiers: .command)
            IconButton(systemName: "gearshape", help: "设置 (⌘,)") { openWindow.show(id: WindowID.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(10)
    }

    private func list(at date: Date) -> some View {
        let shared = sharedPeriod
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, account in
                    AccountRow(account: account, date: date, shortcut: index < 9 ? index + 1 : nil,
                               copied: copiedID == account.id, grouped: groupDigits,
                               showsOwnCountdown: account.period != shared) {
                        copy(account)
                    }
                    .contextMenu { menu(for: account, at: date) }
                }
            }
            .padding(6)
        }
        .frame(height: min(CGFloat(filtered.count) * 56 + 12, 420))
    }

    @ViewBuilder
    private func menu(for account: Account, at date: Date) -> some View {
        Button("复制验证码") { copy(account) }
        Button("复制下一个验证码") {
            if let next = account.code(at: date.addingTimeInterval(account.secondsRemaining(at: date) + 0.5)) {
                copy(account, code: next)
            }
        }
        Divider()
        Button("编辑…") { openWindow.show(id: WindowID.edit, value: account.id) }
        Button("在菜单栏中隐藏") { store.setHidden(account, true) }
        Button("管理账户…") { manageAccounts() }
        Divider()
        Button("复制 otpauth 链接") { Clipboard.copy(account.otpauthURL, clearAfter: clearAfter) }
        Divider()
        Button("删除…", role: .destructive) { confirmDelete(account, from: store) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.accounts.isEmpty ? "lock.shield" : "eye.slash")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            if store.accounts.isEmpty {
                Text("还没有账户").font(.headline)
                Text("扫描二维码或粘贴 otpauth:// 链接来添加").font(.caption).foregroundStyle(.secondary)
                Button("添加账户") { openWindow.show(id: WindowID.add) }.controlSize(.large)
            } else {
                Text("所有账户都已隐藏").font(.headline)
                Button("管理账户") { manageAccounts() }.controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            (visible.isEmpty ? Text(verbatim: "OTPBar") : Text("点击复制 · ⌘1–9 快速复制 · ↩ 复制首项"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
                .focusable(false)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    /// Invisible buttons that give ⌘1…⌘9 shortcuts for the visible accounts.
    private var shortcuts: some View {
        ZStack {
            ForEach(0..<min(9, filtered.count), id: \.self) { i in
                Button("") { copy(filtered[i]) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func copy(_ account: Account, code: String? = nil) {
        guard let code = code ?? account.code() else { return }
        Clipboard.copy(code, clearAfter: clearAfter)
        copiedID = account.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == account.id { copiedID = nil }
        }
        if closeAfterCopy {
            // Capture the panel now so a window focused in the meantime is never closed by mistake.
            let panel = NSApp.keyWindow
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { panel?.close() }
        }
    }

    private func manageAccounts() {
        settingsTab = SettingsTab.accounts
        openWindow.show(id: WindowID.settings)
    }
}

struct AccountRow: View {
    let account: Account
    let date: Date
    let shortcut: Int?
    let copied: Bool
    let grouped: Bool
    /// Only accounts whose period differs from the shared countdown bar get their own ring.
    let showsOwnCountdown: Bool
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        let code = account.code(at: date)
        let remaining = account.secondsRemaining(at: date)
        Button(action: onCopy) {
            HStack(spacing: 10) {
                IssuerBadge(text: account.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if !account.subtitle.isEmpty {
                        Text(account.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                ZStack(alignment: .trailing) {
                    Text(code.map { formatCode($0, grouped: grouped) } ?? String(localized: "密钥无效"))
                        .font(.system(size: code == nil ? 12 : 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(code == nil ? Color.red : Color.primary)
                        .opacity(copied ? 0 : 1)
                    if copied {
                        Label("已复制", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }
                if showsOwnCountdown {
                    CountdownRing(remaining: remaining, period: Double(account.period))
                        .help("此账户周期为 \(account.period) 秒")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(shortcut.map { String(localized: "点击复制（⌘\($0)）· 右键更多操作") } ?? String(localized: "点击复制 · 右键更多操作"))
    }
}

/// Rainbow countdown under the search field: 6 colors × 5 cells. One cell goes out per tick from the
/// purple end, so the final seconds are red; the red cells pulse at the end and the bar refills in a wave.
struct CountdownBar: View {
    static let cellCount = 30
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.27, blue: 0.23), // red
        Color(red: 1.00, green: 0.62, blue: 0.04), // orange
        Color(red: 1.00, green: 0.84, blue: 0.04), // yellow
        Color(red: 0.19, green: 0.82, blue: 0.35), // green
        Color(red: 0.04, green: 0.52, blue: 1.00), // blue
        Color(red: 0.75, green: 0.35, blue: 0.95), // purple
    ]

    /// Color of the band the countdown is currently in.
    static func color(remaining: Double, period: Double) -> Color {
        let lit = Int((remaining / period * Double(cellCount)).rounded(.up))
        return colors[min(colors.count - 1, max(0, lit - 1) / (cellCount / colors.count))]
    }

    let date: Date
    let period: Int

    var body: some View {
        let p = Double(period)
        let remaining = p - date.timeIntervalSince1970.truncatingRemainder(dividingBy: p)
        let lit = min(Self.cellCount, Int((remaining / p * Double(Self.cellCount)).rounded(.up)))
        let refilling = lit == Self.cellCount
        let finalBand = lit <= Self.cellCount / Self.colors.count
        let beat = Int(date.timeIntervalSince1970.rounded()) % 2 == 0
        let band = Self.cellCount / Self.colors.count
        HStack(alignment: .top, spacing: 2) {
            ForEach(0..<Self.cellCount, id: \.self) { i in
                let color = Self.colors[i / band]
                let on = i < lit
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(on ? color : color.opacity(0.13))
                        .shadow(color: on ? color.opacity(0.55) : .clear, radius: on ? 2.5 : 0)
                        // Cells go out instantly; only the refill at a new period is animated.
                        .transaction { t in
                            t.animation = refilling
                                ? .spring(response: 0.35, dampingFraction: 0.6).delay(Double(i) * 0.012)
                                : nil
                        }
                        .frame(height: 5)
                        .scaleEffect(y: on && finalBand && beat ? 1.45 : 1)
                        .animation(.easeInOut(duration: 0.4), value: beat)
                    // Seconds marker under the last cell of each color band: 5, 10, … (scaled for other periods).
                    Color.clear
                        .frame(height: 9)
                        .overlay {
                            if (i + 1) % band == 0 {
                                Text("\((i + 1) * period / Self.cellCount)")
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(color.opacity(on ? 1 : 0.35))
                                    .fixedSize()
                            }
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 5)
        .help("还剩 \(Int(remaining.rounded(.up))) 秒")
    }
}

struct CountdownRing: View {
    let remaining: Double
    let period: Double

    var body: some View {
        let seconds = Int(remaining.rounded(.up))
        let color = CountdownBar.color(remaining: remaining, period: period)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: remaining / period)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: seconds)
            Text("\(seconds)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(width: 22, height: 22)
    }
}

struct IssuerBadge: View {
    let text: String

    var body: some View {
        let initial = text.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        RoundedRectangle(cornerRadius: 7)
            .fill(color.gradient)
            .frame(width: 30, height: 30)
            .overlay(Text(initial).font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
    }

    /// Stable color per issuer name.
    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .cyan, .brown]
        let hash = text.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

struct BannerView: View {
    let banner: AccountStore.Banner

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(banner.text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(banner.isError ? Color.red : Color.green)
    }
}

struct IconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .help(help)
    }
}

// MARK: - Add / Edit window

/// Window content for editing an account by id (accounts may be deleted while the window is open).
struct EditAccountWindow: View {
    @EnvironmentObject var store: AccountStore
    let id: UUID?

    var body: some View {
        if let account = store.accounts.first(where: { $0.id == id }) {
            AccountFormView(editing: account)
        } else {
            Text("账户不存在或已被删除").foregroundStyle(.secondary).frame(width: 440, height: 120)
        }
    }
}

struct AccountFormView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    let editing: Account?

    @State private var link = ""
    @State private var issuer = ""
    @State private var name = ""
    @State private var secret = ""
    @State private var digits = 6
    @State private var period = 30
    @State private var algorithm = OTPAlgorithm.sha1
    @State private var showAdvanced = false
    @State private var message: AccountStore.Banner?

    init(editing: Account?) {
        self.editing = editing
        if let a = editing {
            _issuer = State(initialValue: a.issuer)
            _name = State(initialValue: a.name)
            _secret = State(initialValue: a.secret)
            _digits = State(initialValue: a.digits)
            _period = State(initialValue: a.period)
            _algorithm = State(initialValue: a.algorithm)
            _showAdvanced = State(initialValue: a.digits != 6 || a.period != 30 || a.algorithm != .sha1)
        }
    }

    private var draft: Account {
        Account(id: editing?.id ?? UUID(), issuer: issuer.trimmingCharacters(in: .whitespaces),
                name: name.trimmingCharacters(in: .whitespaces), secret: secret,
                digits: digits, period: period, algorithm: algorithm, hidden: editing?.hidden ?? false)
    }

    private var secretValid: Bool { Base32.decode(secret) != nil }
    private var canSave: Bool {
        secretValid && !(issuer.trimmingCharacters(in: .whitespaces).isEmpty
                         && name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editing == nil {
                GroupBox {
                    importSection.padding(6)
                } label: {
                    Text("快速导入").font(.headline)
                }
            }
            GroupBox {
                manualSection.padding(6)
            } label: {
                (editing == nil ? Text("手动输入") : Text("账户信息")).font(.headline)
            }
            if let message { BannerView(banner: message) }
            HStack {
                if secretValid, let code = draft.code() {
                    Text("当前验证码：\(formatCode(code, grouped: true))")
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(editing == nil ? LocalizedStringKey("完成") : LocalizedStringKey("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? LocalizedStringKey("添加") : LocalizedStringKey("保存"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ImportButton(title: "扫描屏幕二维码", systemImage: "viewfinder", action: scanScreen)
                ImportButton(title: "从剪贴板", systemImage: "doc.on.clipboard", action: importClipboard)
                ImportButton(title: "从图片文件", systemImage: "photo", action: importImageFile)
            }
            HStack(spacing: 6) {
                TextField("粘贴 otpauth:// 或 otpauth-migration:// 链接", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(importLink)
                Button("导入", action: importLink).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("可以连续导入多个账户，窗口不会自动关闭。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField(label: "服务") { TextField("例如 GitHub", text: $issuer).textFieldStyle(.roundedBorder) }
            LabeledField(label: "账户") { TextField("例如 me@example.com", text: $name).textFieldStyle(.roundedBorder) }
            LabeledField(label: "密钥") {
                TextField("Base32 密钥，空格可忽略", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .overlay(alignment: .trailing) {
                        if !secret.isEmpty {
                            Image(systemName: secretValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(secretValid ? .green : .red).padding(.trailing, 6)
                        }
                    }
            }
            DisclosureGroup("高级选项", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("位数", selection: $digits) {
                        ForEach([6, 7, 8], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("周期", selection: $period) {
                        ForEach([30, 60], id: \.self) { Text("\($0) 秒").tag($0) }
                        if ![30, 60].contains(period) { Text("\(period) 秒").tag(period) }
                    }
                    Picker("算法", selection: $algorithm) {
                        ForEach(OTPAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 6)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        if editing != nil {
            store.update(draft)
            dismiss()
        } else {
            message = store.report(added: store.add([draft]), total: 1)
            if message?.isError == false { clearForm() }
        }
    }

    private func clearForm() {
        link = ""
        issuer = ""
        name = ""
        secret = ""
        digits = 6
        period = 30
        algorithm = .sha1
    }

    private func importLink() {
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        message = store.importText(link)
        if message?.isError == false { link = "" }
    }

    private func importClipboard() {
        let pb = NSPasteboard.general
        if let text = pb.string(forType: .string), text.contains("otpauth") {
            message = store.importText(text)
            return
        }
        if let image = NSImage(pasteboard: pb) {
            importQR(QRScanner.decode(image))
            return
        }
        message = .init(text: String(localized: "剪贴板中没有 otpauth 链接或二维码图片"), isError: true)
    }

    private func importImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "选择包含 2FA 二维码的图片")
        guard panel.runModal() == .OK else { return }
        let codes = panel.urls.flatMap { url in NSImage(contentsOf: url).map(QRScanner.decode) ?? [] }
        importQR(codes)
    }

    private func scanScreen() {
        message = nil
        QRScanner.captureScreenRegion { codes in
            NSApp.activate(ignoringOtherApps: true)
            guard let codes else { return } // cancelled
            importQR(codes, fromScreen: true)
        }
    }

    private func importQR(_ codes: [String], fromScreen: Bool = false) {
        let otp = codes.filter { $0.lowercased().hasPrefix("otpauth") }
        guard !otp.isEmpty else {
            let text = codes.isEmpty
                ? (fromScreen ? String(localized: "未识别到二维码。若截图是空白的，请在“系统设置 › 隐私与安全性 › 屏幕与系统录音”中允许 OTPBar。")
                              : String(localized: "图片中未识别到二维码"))
                : String(localized: "二维码不是 2FA（otpauth）格式")
            message = .init(text: text, isError: true)
            return
        }
        message = store.importText(otp.joined(separator: "\n"))
    }
}

struct ImportButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 18))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }
}

struct LabeledField<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Settings window

enum SettingsTab {
    static let accounts = "accounts"
    static let general = "general"
}

struct SettingsView: View {
    @AppStorage(Prefs.settingsTab) private var tab = SettingsTab.accounts

    var body: some View {
        TabView(selection: $tab) {
            AccountManagerView()
                .tabItem { Label("账户管理", systemImage: "person.2") }
                .tag(SettingsTab.accounts)
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .padding(16)
        .frame(width: 500)
    }
}

struct AccountManagerView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("还没有账户").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 340)
            } else {
                List {
                    ForEach(store.accounts) { account in
                        ManagedAccountRow(account: account)
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: 340)
            }
            HStack {
                Text("拖动调整顺序 · 关闭开关即在菜单栏中隐藏")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("显示 \(store.accounts.filter { !$0.hidden }.count) / \(store.accounts.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("添加账户…") { openWindow.show(id: WindowID.add) }
            }
        }
        .padding(4)
    }
}

struct ManagedAccountRow: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("拖动调整顺序")
            IssuerBadge(text: account.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !account.subtitle.isEmpty {
                    Text(account.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .opacity(account.hidden ? 0.45 : 1)
            Spacer()
            Toggle("在菜单栏中显示", isOn: Binding(get: { !account.hidden },
                                            set: { store.setHidden(account, !$0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(account.hidden ? String(localized: "已隐藏，打开以在菜单栏中显示") : String(localized: "在菜单栏中显示"))
            Button { openWindow.show(id: WindowID.edit, value: account.id) } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑")
            Button { confirmDelete(account, from: store) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
        .padding(.vertical, 3)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var store: AccountStore
    @AppStorage(Prefs.clearClipboard) private var clearAfter = 60
    @AppStorage(Prefs.closeAfterCopy) private var closeAfterCopy = true
    @AppStorage(Prefs.groupDigits) private var groupDigits = true
    @AppStorage(Prefs.language) private var language = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var languageChanged = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("复制后自动关闭菜单栏面板", isOn: $closeAfterCopy)
                    Toggle("验证码分组显示（123 456）", isOn: $groupDigits)
                    Toggle("登录时启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                    Picker("自动清除剪贴板", selection: $clearAfter) {
                        Text("关闭").tag(0)
                        Text("30 秒后").tag(30)
                        Text("60 秒后").tag(60)
                        Text("2 分钟后").tag(120)
                    }
                    .fixedSize()
                    Picker("语言", selection: $language) {
                        Text("跟随系统").tag("")
                        Text(verbatim: "简体中文").tag("zh-Hans")
                        Text(verbatim: "English").tag("en")
                    }
                    .fixedSize()
                    .onChange(of: language) { code in
                        applyLanguage(code)
                        languageChanged = true
                    }
                    if languageChanged {
                        HStack {
                            Text("重启 OTPBar 后生效").font(.caption).foregroundStyle(.secondary)
                            Button("立即重启", action: relaunch).controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Text("通用").font(.headline)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("导出备份…", action: exportBackup).disabled(store.accounts.isEmpty)
                        Button("从备份文件导入…", action: importFile)
                    }
                    Text("备份文件是明文 otpauth 链接，包含全部密钥，请妥善保管。账户数据保存在系统“钥匙串”中。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Text("备份").font(.headline)
            }
            HStack {
                Text("OTPBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · \(store.accounts.count) 个账户")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出 OTPBar") { NSApp.terminate(nil) }
            }
        }
        .padding(4)
    }

    /// Overrides the app's language via the per-app AppleLanguages default ("" = follow the system).
    private func applyLanguage(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = String(localized: "设置登录启动失败：\(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "otpbar-backup.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = String(localized: "备份为明文，请保存到安全位置")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = store.accounts.map(\.otpauthURL).joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            message = String(localized: "已导出 \(store.accounts.count) 个账户")
        } catch {
            message = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        message = store.importText(text).text
    }
}
