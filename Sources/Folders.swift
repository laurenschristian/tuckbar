import AppKit

private let foldersKey = "folders"
private let controlCenter = "com.apple.controlcenter"
private let symbols = ["folder", "chart.bar", "gauge.with.dots.needle.33percent", "wrench.and.screwdriver", "bolt",
                       "network", "cloud", "music.note", "star", "tray"]

struct Folder: Codable {
    struct Entry: Codable { let key: String; let name: String }
    var id = UUID().uuidString
    var name: String
    var symbol = "folder"
    var entries: [Entry] = []
}

struct MenuExtra {
    let key: String
    let name: String
    let icon: NSImage?
    let element: AXUIElement

    /// Each AX query costs ~15 ms, so callers pass the bundles they need and the rest run in parallel.
    static func all(in only: Set<String>? = nil) -> [MenuExtra] {
        let running = NSWorkspace.shared.runningApplications
        let bundles = running.compactMap(\.bundleIdentifier)
        let apps = running.filter { app in
            app.activationPolicy != .prohibited && only.map { app.bundleIdentifier.map($0.contains) ?? false } ?? true
        }
        var found = [[MenuExtra]](repeating: [], count: apps.count)
        found.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: apps.count) { out[$0] = extras(of: apps[$0], bundles: bundles) }
        }
        return found.flatMap { $0 }
    }

    private static func extras(of app: NSRunningApplication, bundles: [String]) -> [MenuExtra] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier,
              let bar = ax(element, "AXExtrasMenuBar"),
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let kids = ax(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        let name = app.localizedName ?? bundle
        let icon = app.icon?.copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        // Control Center keeps hidden modules as unlabeled children and reorders them, so key it by identifier.
        if bundle == controlCenter {
            return kids.compactMap { el in
                guard let id = ax(el, kAXIdentifierAttribute) as? String,
                      let desc = ax(el, kAXDescriptionAttribute) as? String else { return nil }
                let label = desc.components(separatedBy: ",")[0]
                return MenuExtra(key: "\(bundle)#\(id)", name: label, icon: icon, element: el)
            }
        }
        // OneDrive runs one process per account, so a lone item still needs a name to stay distinct.
        guard kids.count > 1 || bundles.filter({ $0 == bundle }).count > 1 else {
            return kids.map { MenuExtra(key: "\(bundle)#0", name: name, icon: icon, element: $0) }
        }
        // AX order does not follow screen order, so key these by their tooltip name, e.g. Stats "CPU: Mini".
        return kids.enumerated().map { i, el in
            let label = shortLabel(el, app: name)
            return MenuExtra(key: "\(bundle)#\(label ?? String(i))", name: "\(name): \(label ?? String(i + 1))",
                             icon: icon, element: el)
        }
    }

    /// On-screen frame in CoreGraphics coordinates, or nil while the item is pushed off screen.
    var frame: CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p = ax(element, kAXPositionAttribute), let s = ax(element, kAXSizeAttribute) else { return nil }
        AXValueGetValue(p as! AXValue, .cgPoint, &position)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        let rect = CGRect(origin: position, size: size)
        return NSScreen.screens.contains { $0.cgFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ? rect : nil
    }

    private static func shortLabel(_ el: AXUIElement, app: String) -> String? {
        let raw = [kAXHelpAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
            .compactMap { ax(el, $0) as? String }.first { !$0.isEmpty }
        guard var label = raw?.components(separatedBy: .newlines).first?.components(separatedBy: ":").first else { return nil }
        if label.hasPrefix(app) { label.removeFirst(app.count) }
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013}\u{2014}"))
        return label.isEmpty ? nil : label
    }
}

private func ax(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

final class Folders: NSObject, NSMenuDelegate {
    private var items: [String: NSStatusItem] = [:]
    var menuWillOpen: (() -> Void)?

    /// The folder whose icon is under `point`, with that icon's frame.
    func folder(at point: NSPoint) -> (id: String, frame: NSRect)? {
        for (id, item) in items {
            if let frame = item.button?.window?.frame, NSMouseInRect(point, frame.insetBy(dx: 0, dy: -2), false) { return (id, frame) }
        }
        return nil
    }

    /// Live items of a folder, in folder order.
    func extras(of id: String) -> [MenuExtra] {
        let entries = folders.first { $0.id == id }?.entries ?? []
        let live = MenuExtra.all(in: Set(entries.map { String($0.key.prefix { $0 != "#" }) }))
        return entries.compactMap { entry in live.first { $0.key == entry.key } }
    }
    private let reveal: (@escaping () -> Void) -> Void

    /// `reveal` shows the hidden section if needed, then runs its callback.
    init(reveal: @escaping (@escaping () -> Void) -> Void) {
        self.reveal = reveal
    }

    private var folders: [Folder] {
        get {
            UserDefaults.standard.data(forKey: foldersKey).flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: foldersKey)
            sync()
        }
    }

    func sync() {
        let current = folders
        for (id, item) in items where !current.contains(where: { $0.id == id }) {
            NSStatusBar.system.removeStatusItem(item)
            items[id] = nil
            UserDefaults.standard.removeObject(forKey: positionKey(id))
        }
        for folder in current {
            let item = items[folder.id] ?? makeItem(folder.id)
            item.button?.image = NSImage(systemSymbolName: folder.symbol, accessibilityDescription: folder.name)
            item.button?.image?.isTemplate = true
        }
    }

    private func positionKey(_ id: String) -> String { "NSStatusItem Preferred Position tuckbar.folder.\(id)" }

    private func makeItem(_ id: String) -> NSStatusItem {
        // Positions count from the right edge, so a value just under the chevron's places a new folder right of it.
        // Folders sharing a position swap places between launches, so each gets its own slot.
        let defaults = UserDefaults.standard
        let taken = items.keys.compactMap { defaults.object(forKey: positionKey($0)) as? Double }
        let current = defaults.object(forKey: positionKey(id)) as? Double
        if current.map(taken.contains) ?? true,
           let toggle = defaults.object(forKey: "NSStatusItem Preferred Position tuckbar.toggle") as? Double {
            let free = stride(from: toggle - 1, to: 0, by: -1).first { !taken.contains($0) } ?? 0
            defaults.set(free, forKey: positionKey(id))
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "tuckbar.folder.\(id)"
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier(id)
        menu.delegate = self
        item.menu = menu
        items[id] = item
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu.supermenu == nil { menuWillOpen?() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let raw = menu.identifier?.rawValue, raw.hasPrefix("edit:") { return fillEditMenu(menu, id: String(raw.dropFirst(5))) }
        menu.removeAllItems()
        guard let id = menu.identifier?.rawValue, let folder = folders.first(where: { $0.id == id }) else { return }
        let header = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard AXIsProcessTrusted() else {
            menu.addItem(action("Grant Accessibility Access\u{2026}", #selector(requestAccess), nil))
            return
        }
        if #available(macOS 14, *), !Capture.allowed {
            menu.addItem(action("Show Icons on Hover (Screen Recording)\u{2026}", #selector(requestCapture), nil))
        }
        let live = MenuExtra.all(in: Set(folder.entries.map { String($0.key.prefix { $0 != "#" }) }))
        for entry in folder.entries {
            let extra = live.first { $0.key == entry.key }
            let item = action(extra?.name ?? "\(entry.name) (not running)", #selector(openItem), entry.key)
            item.image = extra?.icon
            item.isEnabled = extra != nil
            menu.addItem(item)
        }
        if folder.entries.isEmpty {
            let empty = NSMenuItem(title: "Empty. Add items below.", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())

        // Listing every app is the slow part, so build this submenu only when it opens.
        let edit = NSMenu()
        edit.identifier = NSUserInterfaceItemIdentifier("edit:\(id)")
        edit.delegate = self
        edit.addItem(NSMenuItem(title: "Loading\u{2026}", action: nil, keyEquivalent: ""))
        menu.addItem(submenu("Add or Remove", edit))

        let icons = NSMenu()
        for name in symbols {
            let item = action(name, #selector(setSymbol), [id, name])
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            item.title = ""
            item.state = folder.symbol == name ? .on : .off
            icons.addItem(item)
        }
        menu.addItem(submenu("Icon", icons))
        menu.addItem(action("Rename\u{2026}", #selector(rename), id))
        menu.addItem(action("Delete Folder", #selector(delete), id))
    }

    private func fillEditMenu(_ menu: NSMenu, id: String) {
        menu.removeAllItems()
        let entries = folders.first { $0.id == id }?.entries ?? []
        for extra in MenuExtra.all().sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let item = action(extra.name, #selector(toggleEntry), [id, extra.key, extra.name])
            item.image = extra.icon
            item.state = entries.contains { $0.key == extra.key } ? .on : .off
            menu.addItem(item)
        }
    }

    private func action(_ title: String, _ selector: Selector, _ object: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc func create() {
        guard let name = prompt("New Folder", "Name the folder, for example Stats or Utilities.", "") else { return }
        folders.append(Folder(name: name))
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { open(key: key) }
    }

    func open(key: String) {
        // Items pushed off screen open their menus off screen too, so reveal them and wait until they land.
        reveal {
            let bundle = String(key.prefix { $0 != "#" })
            guard let extra = MenuExtra.all(in: [bundle]).first(where: { $0.key == key }) else { return }
            Self.press(extra.element, attempts: 25)
        }
    }

    private static func press(_ element: AXUIElement, attempts: Int) {
        var value: CFTypeRef?
        var point = CGPoint(x: -1, y: 0)
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success {
            AXValueGetValue(value as! AXValue, .cgPoint, &point)
        }
        let onScreen = NSScreen.screens.contains { $0.cgFrame.contains(point) }
        guard onScreen || attempts == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { press(element, attempts: attempts - 1) }
            return
        }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    @objc private func toggleEntry(_ sender: NSMenuItem) {
        guard let args = sender.representedObject as? [String] else { return }
        update(args[0]) { folder in
            if let i = folder.entries.firstIndex(where: { $0.key == args[1] }) {
                folder.entries.remove(at: i)
            } else {
                folder.entries.append(.init(key: args[1], name: args[2]))
            }
        }
    }

    @objc private func setSymbol(_ sender: NSMenuItem) {
        guard let args = sender.representedObject as? [String] else { return }
        update(args[0]) { $0.symbol = args[1] }
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let folder = folders.first(where: { $0.id == id }),
              let name = prompt("Rename Folder", "", folder.name) else { return }
        update(id) { $0.name = name }
    }

    @objc private func delete(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        folders.removeAll { $0.id == id }
    }

    @objc private func requestCapture() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @objc private func requestAccess() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    private func update(_ id: String, _ change: (inout Folder) -> Void) {
        var all = folders
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        folders = all
    }

    private func prompt(_ title: String, _ info: String, _ value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame.size.width = 220
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
