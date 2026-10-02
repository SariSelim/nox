import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = PanelController()
        controller = c
        c.show()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "NOX")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let show = NSMenuItem(title: "Paneli göster", action: #selector(showPanel), keyEquivalent: "")
        let hide = NSMenuItem(title: "Paneli gizle", action: #selector(hidePanel), keyEquivalent: "")
        let quit = NSMenuItem(title: "NOX'tan çık", action: #selector(quitApp), keyEquivalent: "q")
        for item in [show, hide, quit] {
            item.target = self
            menu.addItem(item)
        }
        item.menu = menu
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.save()
    }

    @objc private func showPanel() { controller?.show() }
    @objc private func hidePanel() { controller?.hide() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
