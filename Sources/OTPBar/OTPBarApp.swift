import SwiftUI

@main
struct OTPBarApp: App {
    @StateObject private var store = AccountStore()

    /// 18 pt template image drawn by tools/make-icons.swift; falls back to an SF Symbol.
    static let menuBarIcon: NSImage = {
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "OTPBar")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            AccountListView().environmentObject(store)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("添加账户", id: WindowID.add) {
            AccountFormView(editing: nil)
                .environmentObject(store)
                .regularWindow()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        WindowGroup("编辑账户", id: WindowID.edit, for: UUID.self) { $id in
            EditAccountWindow(id: id)
                .environmentObject(store)
                .regularWindow()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("OTPBar 设置", id: WindowID.settings) {
            SettingsView()
                .environmentObject(store)
                .regularWindow()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
