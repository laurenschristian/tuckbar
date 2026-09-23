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
private let showOnHoverKey = "showOnHover"

final class TuckBar: NSObject, NSApplicationDelegate {
    // Each new item lands left of the previous one: toggle, then separator, then always-hidden separator.
    private let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let separator = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let alwaysHidden = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let collapsedLength: CGFloat = 10_000
    private let autoHideDelay: TimeInterval = 10
    private var collapseWork: DispatchWorkItem?
    private var hotkeys: [EventHotKeyRef?] = []
    private var hoverMonitors: [Any] = []
    private var pointerMonitors: [Any] = []
    private var hideCheck: DispatchWorkItem?
    private var stripHide: DispatchWorkItem?
    private var peeking = false
    private var stripCache: [String: [FolderStrip.Item]] = [:]
    private let cover = Cover()
    private let strip = FolderStrip()
    private lazy var folders = Folders { [weak self] done in
        guard let self else { return done() }
        guard isCollapsed else {
            watchPointer()
            return done()
        }
        revealCovered {
            self.watchPointer()
            done()
        }
    }

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
    private var showOnHover: Bool {
        get { UserDefaults.standard.object(forKey: showOnHoverKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showOnHoverKey) }
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
        folders.sync()
        folders.menuWillOpen = { [weak self] in self?.strip.hide() }
        if showOnHover { watchHover() }
        installHotkeyHandler()
        if hotkeyEnabled { registerHotkeys() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // Hidden items are still showing from launch, so capture every folder now while it costs nothing.
            guard #available(macOS 14, *), Capture.allowed else { return self.collapse() }
            Task { @MainActor in
                await self.captureFolders(self.folders.ids)
                self.collapse()
            }
        }
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
        guard let sep = x(separator), let tog = x(toggle), sep < tog else { return cover.hide() }
        collapseWork?.cancel()
        stopWatchingPointer()
        separator.length = collapsedLength
        if alwaysHiddenEnabled, let always = x(alwaysHidden), always < sep {
            alwaysHidden.length = collapsedLength
        }
        toggle.button?.image = chevronLeft
        cover.hide(after: 0.1)
    }

    private func revealHidden() {
        separator.length = NSStatusItem.variableLength
        alwaysHidden.length = NSStatusItem.variableLength
        toggle.button?.image = chevronRight
        collapseWork?.cancel()
    }

    /// Reveals hidden items under a frozen picture of the menu bar when Screen Recording allows it.
    private func revealCovered(then done: @escaping () -> Void) {
        guard #available(macOS 14, *), Capture.allowed else {
            revealHidden()
            return done()
        }
        Task { @MainActor in
            cover.show(await Capture.menuBars())
            revealHidden()
            done()
        }
    }

    @available(macOS 14, *)
    private func peek(_ id: String, anchor: NSRect) {
        guard strip.folderID != id else { return }
        if let cached = stripCache[id] { showStrip(id, cached, anchor) }
        // A running refresh calls pointerMoved when it ends, which picks this folder up.
        guard !peeking, isCollapsed else { return }
        peeking = true
        Task { @MainActor in
            cover.show(await Capture.menuBars())
            revealHidden()
            await captureFolders([id])
            // A strip pick during the refresh already opened an item's menu, so leave the bar revealed for it.
            if pointerMonitors.isEmpty { collapse() }
            peeking = false
            let point = NSEvent.mouseLocation
            let stillHere = folders.folder(at: point)?.id == id || (strip.folderID == id && strip.panelContains(point))
            if stillHere, let items = stripCache[id] { showStrip(id, items, anchor) } else { pointerMoved() }
        }
    }

    /// Captures the given folders' items into the strip cache. The items must already be revealed.
    @available(macOS 14, *)
    private func captureFolders(_ ids: [String]) async {
        let groups = ids.map { ($0, folders.extras(of: $0)) }.filter { !$0.1.isEmpty }
        let extras = groups.flatMap(\.1)
        guard !extras.isEmpty else { return }
        for _ in 0..<60 where extras.contains(where: { $0.frame == nil }) { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let shots = await Capture.menuBars()
        for (id, group) in groups {
            let frames = group.compactMap(\.frame)
            guard frames.count == group.count else { continue }
            let images = Capture.crop(frames, from: shots)
            stripCache[id] = zip(group, images).map { FolderStrip.Item(key: $0.key, name: $0.name, image: $1) }
        }
    }

    private func showStrip(_ id: String, _ items: [FolderStrip.Item], _ anchor: NSRect) {
        strip.show(folderID: id, items: items, below: anchor) { [weak self] key in self?.folders.open(key: key) }
    }

    private func hideStripSoon() {
        guard stripHide == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            stripHide = nil
            if !strip.contains(NSEvent.mouseLocation) { strip.hide() }
        }
        stripHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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

    // Status items live in Control Center windows on macOS 26, so tracking areas never fire; check the pointer instead.
    private func watchHover() {
        let moved: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        hoverMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: moved),
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { moved($0); return $0 },
        ].compactMap { $0 }
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if strip.isVisible, !strip.contains(point) { hideStripSoon() }
        if let folder = folders.folder(at: point) {
            if #available(macOS 14, *), Capture.allowed { peek(folder.id, anchor: folder.frame) } else if isCollapsed { showWhileHovered() }
        } else if isCollapsed, let frame = toggle.button?.window?.frame.onMenuBar(under: point),
                  NSMouseInRect(point, frame.insetBy(dx: 0, dy: -2), false) {
            strip.hide()
            showWhileHovered()
        }
    }

    /// Shows the hidden section until the pointer leaves the menu bar and no menu or popup is open.
    private func showWhileHovered() {
        expand(showAll: false)
        collapseWork?.cancel()
        watchPointer()
        if #available(macOS 14, *), Capture.allowed, !peeking {
            peeking = true
            Task { @MainActor in
                await captureFolders(folders.ids)
                peeking = false
            }
        }
    }

    private func watchPointer() {
        guard pointerMonitors.isEmpty else { return }
        let moved: (NSEvent) -> Void = { [weak self] _ in self?.scheduleHideCheck(after: 0.3) }
        pointerMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .rightMouseUp], handler: moved),
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .rightMouseUp]) { moved($0); return $0 },
        ].compactMap { $0 }
    }

    private func scheduleHideCheck(after delay: TimeInterval) {
        guard hideCheck == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            hideCheck = nil
            if pointerInMenuBar() { return }
            menuOrPopupOpen() ? scheduleHideCheck(after: 0.5) : collapse()
        }
        hideCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopWatchingPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        hideCheck?.cancel()
        hideCheck = nil
    }

    private func pointerInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        return point.y >= screen.frame.maxY - height - 2
    }

    // Menus sit at layer 101 and status item popovers just above it; the status bar itself is layer 25.
    private func menuOrPopupOpen() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return windows?.contains {
            (101..<1000).contains($0[kCGWindowLayer as String] as? Int ?? 0) && $0[kCGWindowOwnerPID as String] as? pid_t != getpid()
        } ?? false
    }

    private func x(_ item: NSStatusItem) -> CGFloat? { item.button?.window?.frame.minX }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Show on Hover", #selector(toggleShowOnHover), on: showOnHover))
        menu.addItem(item("Auto-hide after \(Int(autoHideDelay))s", #selector(toggleAutoHide), on: autoHide))
        menu.addItem(item("Always-hidden section", #selector(toggleAlwaysHidden), on: alwaysHiddenEnabled))
        menu.addItem(item("Hotkey Enabled", #selector(toggleHotkey), on: hotkeyEnabled))
        menu.addItem(item("Set Hotkey (\(hotkeyLabel))\u{2026}", #selector(recordHotkey), on: false))
        let newFolder = NSMenuItem(title: "New Folder\u{2026}", action: #selector(Folders.create), keyEquivalent: "")
        newFolder.target = folders
        menu.addItem(newFolder)
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

    @objc private func toggleShowOnHover() {
        showOnHover.toggle()
        hoverMonitors.forEach(NSEvent.removeMonitor)
        hoverMonitors.removeAll()
        if showOnHover { watchHover() }
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
