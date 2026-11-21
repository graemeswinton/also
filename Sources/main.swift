import Cocoa
import ServiceManagement

let defaults = UserDefaults.standard

enum FontStyle: String {
    case sans, serif, mono

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .sans:
            return NSFont.systemFont(ofSize: size)
        case .serif:
            if let d = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif),
               let f = NSFont(descriptor: d, size: size) { return f }
            return NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// A text view that only ever accepts plain text, so pasted text
/// always takes on the note's own font, size and spacing.
final class PlainTextView: NSTextView {
    /// Space between paragraphs; the separator line sits in the middle of it.
    var separatorGap: CGFloat = 12

    override func didChangeText() {
        super.didChangeText()
        markLinks()
        needsDisplay = true
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Finds web addresses in the note and makes them clickable. They keep the
    /// note's own colour and are only underlined (see linkTextAttributes).
    func markLinks() {
        guard let storage = textStorage, let detector = Self.linkDetector else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.link, range: full)
        detector.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            storage.addAttribute(.link, value: url, range: match.range)
        }
        storage.endEditing()
    }

    /// Draws a faint line under every paragraph that has text and ends with a return.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString
        guard text.length > 0 else { return }

        let origin = textContainerOrigin
        let x0 = origin.x + tc.lineFragmentPadding
        let x1 = origin.x + tc.size.width - tc.lineFragmentPadding
        NSColor.separatorColor.setFill()

        var location = 0
        while location < text.length {
            let para = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(para)
            let last = text.character(at: NSMaxRange(para) - 1)
            guard last == 10 || last == 13 || last == 0x2029 else { continue }   // ends with a return
            let content = text.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }                             // skip blank lines

            // Last line of this paragraph
            let glyph = lm.glyphIndexForCharacter(at: NSMaxRange(para) - 1)
            var lineGlyphs = NSRange()
            let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            let baseline = frag.minY + lm.location(forGlyphAt: lineGlyphs.location).y
            // Height of one line without the paragraph gap, and where the next line's capitals start
            let lineHeight = frag.height - separatorGap
            let capHeight = (font ?? NSFont.systemFont(ofSize: 15)).capHeight
            // Centre the line between this baseline and the top of the next line's capitals
            let y = (origin.y + baseline + (lineHeight + separatorGap - capHeight) / 2).rounded()
            NSRect(x: x0, y: y, width: x1 - x0, height: 1).fill()
        }
    }

    private func pastePlain() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { NSSound.beep(); return }
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: s) {
            textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: typingAttributes))
            didChangeText()
            setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
            scrollRangeToVisible(selectedRange())
        }
    }
    override func paste(_ sender: Any?) { pastePlain() }
    override func pasteAsPlainText(_ sender: Any?) { pastePlain() }
    override func pasteAsRichText(_ sender: Any?) { pastePlain() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return NSPasteboard.general.string(forType: .string) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    // Make ⌘V work even if the menu doesn't route it
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v" {
            pastePlain(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A white (or dark, in dark mode) wash over the frosted background while Also is the active window.
final class TintView: NSView {
    var active = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = active
            ? NSColor.textBackgroundColor.withAlphaComponent(0.92).cgColor
            : NSColor.clear.cgColor
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSMenuItemValidation, NSWindowDelegate {
    var window: NSWindow!
    var textView: PlainTextView!
    var tint: TintView!
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var saveWork: DispatchWorkItem?

    // MARK: Settings

    var fontSize: CGFloat {
        get { let v = defaults.double(forKey: "fontSize"); return v > 0 ? CGFloat(v) : 14 }
        set { defaults.set(Double(min(max(newValue, 10), 40)), forKey: "fontSize") }
    }
    var fontStyle: FontStyle {
        get { FontStyle(rawValue: defaults.string(forKey: "fontStyle") ?? "") ?? .sans }
        set { defaults.set(newValue.rawValue, forKey: "fontStyle") }
    }
    var pinned: Bool {
        get { (defaults.object(forKey: "pinned") as? Bool) ?? true }
        set { defaults.set(newValue, forKey: "pinned") }
    }

    lazy var fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Also", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("note.txt")
    }()

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateFromJot()
        buildMenu()
        setupStatusItem()
        setupLoginItem()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Also"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 180, height: 120)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.setFrameAutosaveName("AlsoWindow")

        // Frosted background, follows light/dark mode
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        window.contentView = effect

        tint = TintView(frame: effect.bounds)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.tint.active = true }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.tint.active = false }

        // Leave a strip at the top for the window buttons / dragging,
        // plus some breathing room above and below the text
        let titleStrip: CGFloat = 28
        let topPadding: CGFloat = 16
        let bottomPadding: CGFloat = 18
        let b = effect.bounds
        let scroll = NSScrollView(frame: NSRect(x: 0, y: bottomPadding, width: b.width,
                                                height: b.height - titleStrip - topPadding - bottomPadding))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let size = scroll.contentSize
        textView = PlainTextView(usingTextLayoutManager: false)   // classic layout, needed for the separator lines
        textView.frame = NSRect(origin: .zero, size: size)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 34, height: 6)   // side padding
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // Links look like the rest of the note, just underlined
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = self
        scroll.documentView = textView
        effect.addSubview(scroll)

        textView.string = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        applyFont()
        applyPin()

        window.delegate = self
        window.makeFirstResponder(textView)
        showNote()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Opening Also from Applications again just shows the note
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showNote(); return false
    }

    // The close button (and ⌘W) hides the note rather than quitting
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideNote(); return false
    }

    // MARK: Menu bar icon

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeStatusIcon()
            button.toolTip = "Also"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Right-click (or Control-click) menu
        statusMenu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            statusMenu.addItem(item)
        }
        add("Keep on Top", #selector(togglePin(_:)))
        add("Open at Login", #selector(toggleLogin(_:)))
        statusMenu.addItem(.separator())
        add("Sans (SF Pro)", #selector(setSans(_:)))
        add("Serif (New York)", #selector(setSerif(_:)))
        add("Mono (SF Mono)", #selector(setMono(_:)))
        statusMenu.addItem(.separator())
        add("Bigger", #selector(bigger(_:)))
        add("Smaller", #selector(smaller(_:)))
        add("Default Size", #selector(resetSize(_:)))
        statusMenu.addItem(.separator())
        add("Quit Also", #selector(quit(_:)))
    }

    /// Lucide "notepad-text" icon (ISC licence), drawn as an 18pt template image
    func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let s: CGFloat = 18.0 / 24.0
            let path = NSBezierPath()
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                path.move(to: NSPoint(x: x1 * s, y: y1 * s))
                path.line(to: NSPoint(x: x2 * s, y: y2 * s))
            }
            line(8, 2, 8, 6); line(12, 2, 12, 6); line(16, 2, 16, 6)
            line(8, 10, 14, 10); line(8, 14, 16, 14); line(8, 18, 13, 18)
            path.append(NSBezierPath(roundedRect: NSRect(x: 4 * s, y: 4 * s, width: 16 * s, height: 18 * s),
                                     xRadius: 2 * s, yRadius: 2 * s))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true   // turns light/dark with the menu bar
        return image
    }

    @objc func statusClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        // If any part of the note is on screen, hide it. If it's hidden or completely
        // covered by other windows, bring it to the front — so every click does something visible.
        let onScreen = window.isVisible && window.occlusionState.contains(.visible)
        if onScreen { hideNote() } else { showNote() }
    }

    func showNote() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hideNote() {
        save()
        window.orderOut(nil)
        NSApp.hide(nil)   // hand focus back to whatever you were using
    }

    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: Open at login

    var opensAtLogin: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    /// Turn on Open at Login the first time Also runs; after that it's your choice.
    func setupLoginItem() {
        guard !defaults.bool(forKey: "loginItemSetUp") else { return }
        defaults.set(true, forKey: "loginItemSetUp")
        if #available(macOS 13.0, *) { try? SMAppService.mainApp.register() }
    }

    @objc func toggleLogin(_ sender: Any?) {
        guard #available(macOS 13.0, *) else { NSSound.beep(); return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }
    func applicationWillTerminate(_ notification: Notification) { save() }

    // MARK: Migration

    /// Also was first called Jot. Bring across the note, settings and window position
    /// from those early builds the first time Also runs. Does nothing for new users.
    func migrateFromJot() {
        guard !defaults.bool(forKey: "migratedFromJot") else { return }
        defaults.set(true, forKey: "migratedFromJot")

        if let old = UserDefaults(suiteName: "studio.actually.jot") {
            for key in ["fontSize", "fontStyle", "pinned"] where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            if let frame = old.string(forKey: "NSWindow Frame JotWindow") {
                defaults.set(frame, forKey: "NSWindow Frame AlsoWindow")
            }
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldNote = support.appendingPathComponent("Jot/note.txt")
        if fm.fileExists(atPath: oldNote.path) && !fm.fileExists(atPath: fileURL.path) {
            try? fm.copyItem(at: oldNote, to: fileURL)
        }
    }

    // MARK: Saving

    func textDidChange(_ notification: Notification) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // Right-click inside the note: add font and size options to the usual text menu
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        // nil = separator
        let items: [(String, Selector)?] = [
            ("Sans (SF Pro)", #selector(setSans(_:))),
            ("Serif (New York)", #selector(setSerif(_:))),
            ("Mono (SF Mono)", #selector(setMono(_:))),
            nil,
            ("Bigger", #selector(bigger(_:))),
            ("Smaller", #selector(smaller(_:))),
            nil,
            ("Keep on Top", #selector(togglePin(_:))),
            nil,
        ]
        for entry in items.reversed() {
            if let (title, action) = entry {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: 0)
            } else {
                menu.insertItem(.separator(), at: 0)
            }
        }
        return menu
    }

    func save() {
        try? textView.string.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: Appearance

    func applyFont() {
        let size = fontSize
        let font = fontStyle.font(size: size)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.3
        para.paragraphSpacing = (size * 0.9).rounded()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: para,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.separatorGap = para.paragraphSpacing
        textView.font = font
        textView.typingAttributes = attrs
        if let storage = textView.textStorage {
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
        }
        textView.markLinks()   // setAttributes clears them
    }

    func applyPin() {
        window.level = pinned ? .floating : .normal
    }

    // MARK: Menu actions

    @objc func togglePin(_ sender: Any?) { pinned.toggle(); applyPin() }
    @objc func setSans(_ sender: Any?) { fontStyle = .sans; applyFont() }
    @objc func setSerif(_ sender: Any?) { fontStyle = .serif; applyFont() }
    @objc func setMono(_ sender: Any?) { fontStyle = .mono; applyFont() }
    @objc func bigger(_ sender: Any?) { fontSize += 1; applyFont() }
    @objc func smaller(_ sender: Any?) { fontSize -= 1; applyFont() }
    @objc func resetSize(_ sender: Any?) { defaults.removeObject(forKey: "fontSize"); applyFont() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        switch action {
        case #selector(togglePin(_:)): item.state = pinned ? .on : .off
        case #selector(toggleLogin(_:)): item.state = opensAtLogin ? .on : .off
        case #selector(setSans(_:)):   item.state = fontStyle == .sans ? .on : .off
        case #selector(setSerif(_:)):  item.state = fontStyle == .serif ? .on : .off
        case #selector(setMono(_:)):   item.state = fontStyle == .mono ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Menus

    func buildMenu() {
        let main = NSMenu()

        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String,
                 _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            menu.addItem(item)
        }

        // App
        let appMenu = NSMenu()
        add(appMenu, "About Also", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        appMenu.addItem(.separator())
        add(appMenu, "Hide Also", #selector(NSApplication.hide(_:)), "h")
        add(appMenu, "Quit Also", #selector(NSApplication.terminate(_:)), "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        // Edit
        let edit = NSMenu(title: "Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)

        // View
        let view = NSMenu(title: "View")
        add(view, "Keep on Top", #selector(togglePin(_:)), "t", [.command, .shift], target: self)
        view.addItem(.separator())
        add(view, "Sans (SF Pro)", #selector(setSans(_:)), "1", target: self)
        add(view, "Serif (New York)", #selector(setSerif(_:)), "2", target: self)
        add(view, "Mono (SF Mono)", #selector(setMono(_:)), "3", target: self)
        view.addItem(.separator())
        add(view, "Bigger", #selector(bigger(_:)), "=", target: self)
        add(view, "Smaller", #selector(smaller(_:)), "-", target: self)
        add(view, "Default Size", #selector(resetSize(_:)), "0", target: self)
        let viewItem = NSMenuItem(); viewItem.submenu = view; main.addItem(viewItem)

        // Window
        let win = NSMenu(title: "Window")
        add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, "Close", #selector(NSWindow.performClose(_:)), "w")
        let winItem = NSMenuItem(); winItem.submenu = win; main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
