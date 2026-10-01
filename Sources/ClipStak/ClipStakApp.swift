import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClipStakCore

final class ClipStakApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store = ClipStore()
    private let hotkey = Hotkey()
    private let bezel = BezelPanel()
    private var statusItem: NSStatusItem!
    private var watcher: Timer?
    private var saveRetry: Timer?
    private var warnedSaveFailure = false
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var bezelVisible = false
    private var suppressPaste = false
    private var ownChangeCount: Int?
    private let supportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClipStak", isDirectory: true)
    private var historyURL: URL {
        supportURL.appendingPathComponent("history.json")
    }
    private lazy var history = HistoryPersistence(url: historyURL)
    private var uncleanURL: URL {
        supportURL.appendingPathComponent("unclean")
    }
    private var importedURL: URL {
        supportURL.appendingPathComponent("imported-flycut")
    }
    private var lockFD: Int32 = -1
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard takeSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let restarted = FileManager.default.fileExists(atPath: uncleanURL.path)
        FileManager.default.createFile(atPath: uncleanURL.path, contents: Data())
        installTerminationHandler()
        loadHistory()
        installStatusItem()
        installHotkey()
        installBezel()
        startWatchingPasteboard()
        promptForAccessibility()
        if restarted {
            notify("ClipStak stopped and is running again.")
        }
        if ProcessInfo.processInfo.environment["CLIPSTAK_SHOW_BEZEL"] == "1" {
            bezel.show(
                clip: Clip(text: "Hold shift-command-V, then release to paste.", appName: "ClipStak", bundlePath: nil, copiedAt: Date()),
                position: "1 of 1",
                hint: "release ⌘ to paste  ·  esc cancels"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if persist() {
            try? FileManager.default.removeItem(at: uncleanURL)
        }
        if lockFD >= 0 { close(lockFD) }
    }

    private func takeSingleInstanceLock() -> Bool {
        let url = supportURL.appendingPathComponent("instance.lock")
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        lockFD = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return true }
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    private func loadHistory() {
        if FileManager.default.fileExists(atPath: historyURL.path) {
            store = history.load()
            if history.backupURL != nil {
                notify("Unreadable history was preserved. A new history was started.")
            } else if !history.canSave {
                notify("History could not be read and is not being saved.")
            }
            return
        }
        guard !FileManager.default.fileExists(atPath: importedURL.path) else { return }
        let flycut = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.generalarcade.flycut/Data/Library/Preferences/com.generalarcade.flycut.plist")
        if let data = try? Data(contentsOf: flycut),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let root = plist as? [String: Any],
           let flyStore = root["store"] as? [String: Any] {
            let clips = ClipStore.importingFlycutStore(flyStore)
            store = ClipStore(clips: clips)
            guard persist() else { return }
        }
        FileManager.default.createFile(atPath: importedURL.path, contents: Data())
    }

    @discardableResult
    private func persist() -> Bool {
        if history.save(store) {
            saveRetry?.invalidate()
            saveRetry = nil
            if warnedSaveFailure {
                warnedSaveFailure = false
                statusItem?.button?.toolTip = "ClipStak — hold ⇧⌘V, release to paste"
                notify("Clipboard history is being saved again.")
            }
            return true
        }
        statusItem?.button?.toolTip = "ClipStak — history is not being saved"
        if !warnedSaveFailure {
            warnedSaveFailure = true
            notify("Clipboard history is not being saved. Check available disk space and permissions.")
        }
        if history.canSave, saveRetry == nil {
            saveRetry = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                self?.saveRetry = nil
                self?.persist()
            }
        }
        return false
    }

    private func installTerminationHandler() {
        // Logout and launchd send SIGTERM. Quit from the menu already calls terminate.
        // Without this, the process dies before the history is saved and the unclean flag is cleared.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }

    private func installStatusItem() {
        let autosave = "ClipStak"
        let positionKey = "NSStatusItem Preferred Position \(autosave)"
        // Preferred position increases toward the left. 280 sits just right of
        // Flycut (295), clear of the notch overflow. Leave a position the user dragged.
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(CGFloat(280), forKey: positionKey)
        }
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(autosave)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = autosave
        statusItem.isVisible = true
        statusItem.button?.image = StatusIcon.image(paused: store.paused)
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.toolTip = history.canSave && history.lastError == nil
            ? "ClipStak — hold ⇧⌘V, release to paste"
            : "ClipStak — history is not being saved"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            menu.cancelTracking()
            togglePause()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if history.lastError != nil {
            let warning = NSMenuItem(title: "History is not being saved", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        let hint = NSMenuItem(title: "Hold ⇧⌘V, release to paste", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        if store.clips.isEmpty {
            let empty = NSMenuItem(title: "Nothing copied yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for item in store.menuItems() {
                let entry = NSMenuItem(title: item.title, action: #selector(pasteMenuItem(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = item.index
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        let pause = NSMenuItem(
            title: store.paused ? "Resume Capture" : "Pause Capture",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)
        let sticky = NSMenuItem(title: "Sticky Bezel", action: #selector(toggleSticky), keyEquivalent: "")
        sticky.target = self
        sticky.state = store.sticky ? .on : .off
        menu.addItem(sticky)
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(NSMenuItem(title: "Quit ClipStak", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
    }

    @objc private func togglePause() {
        store.paused.toggle()
        statusItem.button?.image = StatusIcon.image(paused: store.paused)
        persist()
    }

    @objc private func toggleSticky() {
        store.sticky.toggle()
        persist()
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "The clips ClipStak has saved will be deleted."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clear()
        persist()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func pasteMenuItem(_ sender: NSMenuItem) {
        store.select(sender.tag)
        pasteCurrent()
    }

    private func installHotkey() {
        hotkey.onPress = { [weak self] in
            self?.hotkeyPressed()
        }
        hotkey.install()
    }

    private func installBezel() {
        bezel.onKey = { [weak self] event in self?.bezelKey(event) }
        bezel.onFlags = { [weak self] event in self?.flagsChanged(event) }
        bezel.onScroll = { [weak self] delta in
            if delta > 0 { self?.moveNewer() } else if delta < 0 { self?.moveOlder() }
        }
        bezel.onDoubleClick = { [weak self] in self?.pasteCurrent() }
    }

    private func hotkeyPressed() {
        if !bezelVisible {
            showBezel()
        } else {
            moveOlder()
        }
    }

    private func showBezel(armPaste: Bool = true) {
        suppressPaste = !armPaste
        bezelVisible = true
        bezel.show(clip: store.current, position: store.positionLabel, hint: hint)
        installFlagMonitors()
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
        if armPaste, modifiers.isEmpty {
            modifiersReleased()
        }
    }

    private var hint: String {
        store.sticky ? "return pastes  ·  esc closes" : "release ⌘ to paste  ·  esc cancels"
    }

    private func refreshBezel() {
        guard bezelVisible else { return }
        bezel.update(clip: store.current, position: store.positionLabel, hint: hint)
    }

    private func hideBezel() {
        bezelVisible = false
        removeFlagMonitors()
        bezel.orderOut(nil)
    }

    private func installFlagMonitors() {
        removeFlagMonitors()
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsChanged(event)
            return event
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsChanged(event)
        }
    }

    private func removeFlagMonitors() {
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    private func flagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers.isEmpty {
            modifiersReleased()
        }
    }

    private func modifiersReleased() {
        guard bezelVisible, !suppressPaste, !store.sticky else { return }
        pasteCurrent()
    }

    private func moveOlder() {
        _ = store.older()
        refreshBezel()
    }

    private func moveNewer() {
        _ = store.newer()
        refreshBezel()
    }

    private func bezelKey(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_ANSI_V),
           event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.shift) {
            return
        }
        switch event.keyCode {
        case UInt16(kVK_Escape):
            suppressPaste = true
            hideBezel()
        case UInt16(kVK_Return):
            pasteCurrent()
        case UInt16(kVK_ANSI_KeypadEnter):
            store.moveCurrentToFront()
            persist()
            suppressPaste = true
            hideBezel()
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            _ = store.deleteCurrent()
            persist()
            suppressPaste = true
            hideBezel()
        case UInt16(kVK_UpArrow), UInt16(kVK_LeftArrow):
            moveNewer()
        case UInt16(kVK_DownArrow), UInt16(kVK_RightArrow):
            moveOlder()
        case UInt16(kVK_Home):
            store.newest()
            refreshBezel()
        case UInt16(kVK_End):
            store.oldest()
            refreshBezel()
        case UInt16(kVK_PageUp):
            store.pageNewer()
            refreshBezel()
        case UInt16(kVK_PageDown):
            store.pageOlder()
            refreshBezel()
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased() else { return }
            switch character {
            case "k": moveNewer()
            case "j": moveOlder()
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                store.jumpToNumberKey(Int(character) ?? 1)
                refreshBezel()
            case "0":
                store.jumpToNumberKey(0)
                refreshBezel()
            default:
                break
            }
        }
    }

    private func pasteCurrent() {
        guard let text = store.current?.text else {
            suppressPaste = true
            hideBezel()
            return
        }
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        suppressPaste = true
        hideBezel()
        writeToPasteboard(text)
        let expectedChangeCount = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard ClipboardPolicy.canCompletePaste(
                expectedChangeCount: expectedChangeCount,
                currentChangeCount: NSPasteboard.general.changeCount,
                targetPID: targetPID,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
            ) else { return }
            postCommandV()
        }
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownChangeCount = pasteboard.changeCount
    }

    private func startWatchingPasteboard() {
        var lastCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            let count = pasteboard.changeCount
            if count == lastCount { return }
            lastCount = count
            if count == self.ownChangeCount { return }
            guard ClipboardPolicy.shouldCapture(types: pasteboard.types?.map(\.rawValue) ?? []) else { return }
            guard let text = pasteboard.string(forType: .string) else { return }
            let front = NSWorkspace.shared.frontmostApplication
            let result = self.store.record(
                text: text,
                appName: front?.localizedName ?? "",
                bundlePath: front?.bundleURL?.path,
                at: Date()
            )
            if result == .recorded {
                self.persist()
            }
        }
        watcher = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            notify("ClipStak needs Accessibility permission to paste.")
        }
    }

    private func notify(_ message: String) {
        let script = "display notification \"\(message)\" with title \"ClipStak\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

private func postCommandV() {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
    let key = CGKeyCode(kVK_ANSI_V)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
    // 0x8 is the physical Command key. Some apps ignore a chord that only sets the symbolic flag.
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private enum StatusIcon {
    static func image(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let fill = NSColor(calibratedRed: 0.86, green: 0.16, blue: 0.18, alpha: paused ? 0.35 : 1)
            fill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            NSColor.white.withAlphaComponent(paused ? 0.5 : 1).setStroke()
            let lines = NSBezierPath()
            lines.lineWidth = 1.4
            lines.lineCapStyle = .round
            for row in 0..<3 {
                let y = 5.0 + CGFloat(row) * 3.2
                lines.move(to: NSPoint(x: 4.5, y: y))
                lines.line(to: NSPoint(x: 13.5, y: y))
            }
            lines.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
