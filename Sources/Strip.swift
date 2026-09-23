import AppKit
import ScreenCaptureKit

extension NSScreen {
    var menuBarHeight: CGFloat { max(NSStatusBar.system.thickness, frame.maxY - visibleFrame.maxY) }
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
    /// Frame in CoreGraphics global coordinates (top-left origin), which AX positions use.
    var cgFrame: CGRect {
        let primary = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height)
    }
}

extension NSRect {
    /// Status item windows follow the active menu bar, so move this frame to the menu bar of the screen under `point`.
    func onMenuBar(under point: NSPoint) -> NSRect {
        let screens = NSScreen.screens
        guard let target = screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let source = screens.first(where: { $0.frame.intersects(self) }), source != target else { return self }
        return offsetBy(dx: target.frame.maxX - source.frame.maxX, dy: target.frame.maxY - source.frame.maxY)
    }
}

@available(macOS 14, *)
enum Capture {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures each screen's menu bar strip, leaving out TuckBar's own windows.
    static func menuBars() async -> [(NSScreen, CGImage)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let screens = NSScreen.screens
        let shots = await withTaskGroup(of: (Int, CGImage)?.self) { group in
            for (index, screen) in screens.enumerated() {
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.menuBarHeight)
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.menuBarHeight * screen.backingScaleFactor)
                config.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: own)
                group.addTask {
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return image.map { (index, $0) }
                }
            }
            return await group.reduce(into: [(Int, CGImage)]()) { if let shot = $1 { $0.append(shot) } }
        }
        return shots.map { (screens[$0.0], $0.1) }
    }

    /// Crops each AX frame (CoreGraphics coordinates) out of the matching menu bar capture.
    static func crop(_ frames: [CGRect], from shots: [(NSScreen, CGImage)]) -> [NSImage?] {
        frames.map { rect in
            guard let (screen, image) = shots.first(where: { $0.0.cgFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
            else { return nil }
            let scale = CGFloat(image.width) / screen.frame.width
            let local = rect.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY)
            let pixels = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
            return image.cropping(to: pixels.integral).map { NSImage(cgImage: $0, size: rect.size) }
        }
    }
}

/// A frozen picture of each menu bar, so hidden items can be shown and captured without anything visibly moving.
final class Cover {
    private var windows: [NSWindow] = []
    private var pendingHide: DispatchWorkItem?
    var isShown: Bool { !windows.isEmpty }

    func show(_ shots: [(NSScreen, CGImage)]) {
        hide()
        windows = shots.map { screen, image in
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - screen.menuBarHeight,
                               width: screen.frame.width, height: screen.menuBarHeight)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.contentView = NSImageView(image: NSImage(cgImage: image, size: frame.size))
            window.orderFrontRegardless()
            return window
        }
    }

    func hide() {
        pendingHide?.cancel()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// Hides after the menu bar has had time to lay out, unless a newer `show` comes first.
    func hide(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// The small panel under a folder that shows that folder's icons.
final class FolderStrip: NSObject {
    struct Item { let key: String; let name: String; let image: NSImage? }
    private let panel: NSPanel
    private var keys: [String] = []
    private var anchor = NSRect.zero
    private var onPick: ((String) -> Void)?
    private var shownID: String?
    var folderID: String? { isVisible ? shownID : nil }

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        super.init()
    }

    var isVisible: Bool { panel.isVisible }

    /// The panel, its folder icon, and the gap between them, but not the neighbouring folders.
    func contains(_ point: NSPoint) -> Bool {
        let gap = NSRect(x: anchor.minX, y: panel.frame.maxY, width: anchor.width, height: anchor.minY - panel.frame.maxY)
        return isVisible && [panel.frame.insetBy(dx: -6, dy: -6), anchor.insetBy(dx: 0, dy: -2), gap]
            .contains { NSMouseInRect(point, $0, false) }
    }

    func panelContains(_ point: NSPoint) -> Bool { isVisible && NSMouseInRect(point, panel.frame.insetBy(dx: -6, dy: -6), false) }

    func show(folderID: String, items: [Item], below anchor: NSRect,
              onPick: @escaping (String) -> Void) {
        shownID = folderID
        self.anchor = anchor
        self.onPick = onPick
        keys = items.map(\.key)
        let buttons = items.enumerated().map { i, item -> NSButton in
            let button = NSButton(image: item.image ?? NSImage(), target: self, action: #selector(picked))
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.tag = i
            button.toolTip = item.name
            if item.image == nil { button.title = item.name }
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        let size = stack.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let maxX = (screen?.frame.maxX ?? anchor.maxX) - size.width - 4
        let x = min(max(anchor.midX - size.width / 2, screen?.frame.minX ?? 0), maxX)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func picked(_ sender: NSButton) {
        let key = keys[sender.tag]
        hide()
        onPick?(key)
    }
}
