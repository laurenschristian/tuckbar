import AppKit
import Carbon.HIToolbox
import ServiceManagement

private let toggleKey = "tuckbar.toggle"
private let separatorKey = "tuckbar.separator"
private let alwaysHiddenKey = "tuckbar.alwayshidden"
private let autoHideKey = "autoHide"
private let alwaysHiddenEnabledKey = "alwaysHiddenEnabled"
private let hotkeyEnabledKey = "hotkeyEnabled"
private let hotkeyCodeKey = "hotkeyCode"
private let hotkeyModifiersKey = "hotkeyModifiers"
private let hotkeyLabelKey = "hotkeyLabel"

final class TuckBar: NSObject, NSApplicationDelegate {
    // Each new item lands left of the previous one: toggle, then separator, then always-hidden separator.
    private let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let separator = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let alwaysHidden = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let collapsedLength: CGFloat = 10_000
    private let autoHideDelay: TimeInterval = 10
    private var collapseWork: DispatchWorkItem?
    private var hotkeys: [EventHotKeyRef?] = []

    private lazy var chevronLeft = symbol("chevron.left")
    private lazy var chevronRight = symbol("chevron.right")

    private var isCollapsed: Bool { separator.length == collapsedLength }
    private var autoHide: Bool {
        get { UserDefaults.standard.bool(forKey: autoHideKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoHideKey) }
    }
    private var alwaysHiddenEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysHiddenEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysHiddenEnabledKey) }
    }
    private var hotkeyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hotkeyEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hotkeyEnabledKey) }
    }
    private var hotkeyCode: UInt32 { UInt32(UserDefaults.standard.object(forKey: hotkeyCodeKey) as? Int ?? kVK_ANSI_T) }
    private var hotkeyModifiers: UInt32 {
        UInt32(UserDefaults.standard.object(forKey: hotkeyModifiersKey) as? Int ?? (cmdKey | optionKey | controlKey))
    }
    private var hotkeyLabel: String { UserDefaults.standard.string(forKey: hotkeyLabelKey) ?? "\u{2303}\u{2325}\u{2318}T" }

    func applicationDidFinishLaunching(_: Notification) {
        toggle.autosaveName = toggleKey
        separator.autosaveName = separatorKey
        alwaysHidden.autosaveName = alwaysHiddenKey

        separator.button?.image = symbol("poweron")
        separator.button?.appearsDisabled = true
        alwaysHidden.button?.image = symbol("pause")
        alwaysHidden.button?.appearsDisabled = true
        alwaysHidden.isVisible = alwaysHiddenEnabled

        if let button = toggle.button {
            button.image = chevronRight
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        installHotkeyHandler()
        if hotkeyEnabled { registerHotkeys() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.collapse() }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            expand(showAll: true)
        } else {
            toggleCollapsed()
        }
    }

    private func toggleCollapsed() {
        isCollapsed ? expand(showAll: false) : collapse()
    }

    private func collapse() {
        // Collapsing with a separator right of the toggle would push the toggle off screen too.
        guard let sep = x(separator), let tog = x(toggle), sep < tog else { return }
        collapseWork?.cancel()
        separator.length = collapsedLength
        if alwaysHiddenEnabled, let always = x(alwaysHidden), always < sep {
            alwaysHidden.length = collapsedLength
        }
        toggle.button?.image = chevronLeft
    }

    private func expand(showAll: Bool) {
        separator.length = NSStatusItem.variableLength
        if showAll { alwaysHidden.length = NSStatusItem.variableLength }
        toggle.button?.image = chevronRight
        collapseWork?.cancel()
        guard autoHide || showAll else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: work)
    }

    private func x(_ item: NSStatusItem) -> CGFloat? { item.button?.window?.frame.minX }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Auto-hide after \(Int(autoHideDelay))s", #selector(toggleAutoHide), on: autoHide))
        menu.addItem(item("Always-hidden section", #selector(toggleAlwaysHidden), on: alwaysHiddenEnabled))
        menu.addItem(item("Hotkey Enabled", #selector(toggleHotkey), on: hotkeyEnabled))
        menu.addItem(item("Set Hotkey (\(hotkeyLabel))\u{2026}", #selector(recordHotkey), on: false))
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

    @objc private func toggleAlwaysHidden() {
        alwaysHiddenEnabled.toggle()
        alwaysHidden.length = NSStatusItem.variableLength
        alwaysHidden.isVisible = alwaysHiddenEnabled
        expand(showAll: false)
    }

    @objc private func toggleHotkey() {
        hotkeyEnabled.toggle()
        hotkeyEnabled ? registerHotkeys() : unregisterHotkeys()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
    }

    @objc private func recordHotkey() {
        unregisterHotkeys()
        defer { if hotkeyEnabled { registerHotkeys() } }
        let alert = NSAlert()
        alert.messageText = "Set Hotkey"
        alert.informativeText = "Press the new shortcut. It must include Command, Option, or Control. Shift is added for Show All."
        alert.addButton(withTitle: "Cancel")
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { return event }
            var mods = 0, label = ""
            if flags.contains(.control) { mods |= controlKey; label += "\u{2303}" }
            if flags.contains(.option) { mods |= optionKey; label += "\u{2325}" }
            if flags.contains(.shift) { mods |= shiftKey; label += "\u{21E7}" }
            if flags.contains(.command) { mods |= cmdKey; label += "\u{2318}" }
            let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
            label += key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Key \(event.keyCode)" : key
            let defaults = UserDefaults.standard
            defaults.set(Int(event.keyCode), forKey: hotkeyCodeKey)
            defaults.set(mods, forKey: hotkeyModifiersKey)
            defaults.set(label, forKey: hotkeyLabelKey)
            defaults.set(true, forKey: hotkeyEnabledKey)
            NSApp.stopModal()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // Carbon hotkeys need no Accessibility permission. ID 1 toggles, ID 2 (plus Shift) shows everything.
    private func installHotkeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let app = Unmanaged<TuckBar>.fromOpaque(context!).takeUnretainedValue()
            id.id == 2 ? app.expand(showAll: true) : app.toggleCollapsed()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotkeys() {
        unregisterHotkeys()
        var pairs = [(UInt32(1), hotkeyModifiers)]
        if hotkeyModifiers & UInt32(shiftKey) == 0 { pairs.append((2, hotkeyModifiers | UInt32(shiftKey))) }
        for (id, mods) in pairs {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(hotkeyCode, mods, EventHotKeyID(signature: OSType(0x5475_636B), id: id),
                                GetApplicationEventTarget(), 0, &ref)
            hotkeys.append(ref)
        }
    }

    private func unregisterHotkeys() {
        hotkeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        hotkeys.removeAll()
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
