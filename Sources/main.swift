import AppKit
import ServiceManagement

private let toggleKey = "tuckbar.toggle"
private let separatorKey = "tuckbar.separator"
private let autoHideKey = "autoHide"

final class TuckBar: NSObject, NSApplicationDelegate {
    // Created first so it sits rightmost; the separator lands to its left.
    private let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let separator = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let collapsedLength: CGFloat = 10_000
    private let autoHideDelay: TimeInterval = 10
    private var collapseWork: DispatchWorkItem?

    private lazy var chevronLeft = symbol("chevron.left")
    private lazy var chevronRight = symbol("chevron.right")

    private var isCollapsed: Bool { separator.length == collapsedLength }
    private var autoHide: Bool {
        get { UserDefaults.standard.bool(forKey: autoHideKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoHideKey) }
    }

    func applicationDidFinishLaunching(_: Notification) {
        toggle.autosaveName = toggleKey
        separator.autosaveName = separatorKey

        separator.button?.image = symbol("poweron")
        separator.button?.appearsDisabled = true

        if let button = toggle.button {
            button.image = chevronRight
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.collapse() }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            showMenu()
        } else {
            isCollapsed ? expand() : collapse()
        }
    }

    private func collapse() {
        // Collapsing with the separator right of the toggle would push the toggle off screen too.
        guard let sep = separator.button?.window?.frame.minX,
              let tog = toggle.button?.window?.frame.minX, sep < tog else { return }
        collapseWork?.cancel()
        separator.length = collapsedLength
        toggle.button?.image = chevronLeft
    }

    private func expand() {
        separator.length = NSStatusItem.variableLength
        toggle.button?.image = chevronRight
        guard autoHide else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: work)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Auto-hide after \(Int(autoHideDelay))s", #selector(toggleAutoHide), on: autoHide))
        menu.addItem(item("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(withTitle: "TuckBar \(version)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit TuckBar", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        toggle.menu = menu
        toggle.button?.performClick(nil)
        toggle.menu = nil
    }

    private func item(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleAutoHide() {
        autoHide.toggle()
        if !autoHide { collapseWork?.cancel() }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = TuckBar()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
