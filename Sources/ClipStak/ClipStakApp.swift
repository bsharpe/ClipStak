import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClipStakCore
import ClipStakClipboard
import os

final class ClipStakApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store = ClipStore()
    private let hotkey = Hotkey()
    private let bezel = BezelPanel()
    private let sheet = ContactSheetPanel()
    private var statusItem: NSStatusItem!
    private var watcher: Timer?
    private var saveRetry: Timer?
    private var warnedSaveFailure = false
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var modifierPoll: Timer?
    private var bezelVisible = false
    private var sheetVisible = false
    private var suppressPaste = false
    private var releaseArmed = false
    private var pasteGeneration = 0
    private var pasteTarget: NSRunningApplication?
    private let pasteLog = Logger(subsystem: "com.bsharpe.clipstak", category: "Paste")
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
        installSheet()
        startWatchingPasteboard()
        refreshAccessibilityStatus()
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
        rememberPasteTarget()
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            menu.cancelTracking()
            togglePause()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !CGPreflightPostEventAccess() {
            let permission = NSMenuItem(title: "Enable Automatic Paste…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            permission.target = self
            menu.addItem(permission)
            menu.addItem(.separator())
        }
        if history.lastError != nil {
            let warning = NSMenuItem(title: "History is not being saved", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        let hint = NSMenuItem(title: "Hold ⇧⌘V, release to paste", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let sheetHint = NSMenuItem(title: "Press ⌃⌘V to pick from all clips", action: nil, keyEquivalent: "")
        sheetHint.isEnabled = false
        menu.addItem(sheetHint)
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
                if let thumbnail = store.clips[item.index].image?.thumbnail(maxPixelSize: 36) {
                    let scale = 18 / CGFloat(max(thumbnail.width, thumbnail.height))
                    entry.image = NSImage(cgImage: thumbnail, size: NSSize(
                        width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale
                    ))
                }
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
        hotkey.onPress = { [weak self] chord in
            switch chord {
            case .bezel: self?.hotkeyPressed()
            case .sheet: self?.toggleSheet()
            }
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

    private func installSheet() {
        sheet.onChoose = { [weak self] index in
            guard let self else { return }
            store.select(index)
            hideSheet()
            pasteCurrent()
        }
        sheet.onClose = { [weak self] in self?.hideSheet() }
    }

    private func toggleSheet() {
        guard !sheetVisible else {
            hideSheet()
            return
        }
        cancelPendingPaste()
        if bezelVisible {
            suppressPaste = true
            hideBezel()
        }
        rememberPasteTarget()
        sheetVisible = true
        sheet.show(clips: store.clips, selected: 0)
    }

    private func hideSheet() {
        // orderOut resigns key, which reports close again.
        guard sheetVisible else { return }
        sheetVisible = false
        sheet.orderOut(nil)
    }

    private func hotkeyPressed() {
        hideSheet()
        if !bezelVisible {
            showBezel()
        } else {
            moveOlder()
        }
    }

    private func showBezel(armPaste: Bool = true) {
        cancelPendingPaste()
        rememberPasteTarget()
        suppressPaste = !armPaste
        bezelVisible = true
        bezel.show(clip: store.current, position: store.positionLabel, hint: hint)
        installFlagMonitors()
        let hardware = hardwareModifiers()
        releaseArmed = !hardware.isEmpty
        if ReleasePaste.shouldPaste(
            reported: hardware,
            hardware: hardware,
            bezelVisible: true,
            suppressPaste: suppressPaste,
            sticky: store.sticky
        ) {
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
        releaseArmed = false
        removeFlagMonitors()
        bezel.orderOut(nil)
    }

    private func cancelPendingPaste() {
        pasteGeneration += 1
    }

    private func rememberPasteTarget() {
        let app = NSWorkspace.shared.frontmostApplication
        pasteTarget = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
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
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.modifierPollFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierPoll = timer
    }

    private func removeFlagMonitors() {
        modifierPoll?.invalidate()
        modifierPoll = nil
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
        let hardware = hardwareModifiers()
        if !hardware.isEmpty { releaseArmed = true }
        guard ReleasePaste.shouldPaste(
            reported: heldModifiers(event.modifierFlags),
            hardware: hardware,
            bezelVisible: bezelVisible,
            suppressPaste: suppressPaste,
            sticky: store.sticky
        ) else { return }
        modifiersReleased()
    }

    private func modifierPollFired() {
        let hardware = hardwareModifiers()
        if !hardware.isEmpty {
            releaseArmed = true
            return
        }
        // A tap pastes from showBezel. The poll only finishes a hold we have seen.
        guard releaseArmed else { return }
        guard ReleasePaste.shouldPaste(
            reported: hardware,
            hardware: hardware,
            bezelVisible: bezelVisible,
            suppressPaste: suppressPaste,
            sticky: store.sticky
        ) else { return }
        modifiersReleased()
    }

    private func modifiersReleased() {
        pasteCurrent()
    }

    private func heldModifiers(_ flags: NSEvent.ModifierFlags) -> HeldModifiers {
        var held = HeldModifiers()
        if flags.contains(.command) { held.insert(.command) }
        if flags.contains(.shift) { held.insert(.shift) }
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.control) { held.insert(.control) }
        return held
    }

    private func hardwareModifiers() -> HeldModifiers {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return heldModifiers(NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
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
            cancelPendingPaste()
            hideBezel()
        case UInt16(kVK_Return):
            pasteCurrent()
        case UInt16(kVK_ANSI_KeypadEnter):
            store.moveCurrentToFront()
            persist()
            suppressPaste = true
            cancelPendingPaste()
            hideBezel()
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            _ = store.deleteCurrent()
            persist()
            suppressPaste = true
            cancelPendingPaste()
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
        pasteLog.notice("Paste requested")
        guard let content = store.current?.content else {
            suppressPaste = true
            hideBezel()
            return
        }
        suppressPaste = true
        guard writeToPasteboard(content) else {
            hideBezel()
            notify("The selected clip could not be copied to the clipboard.")
            return
        }
        // Flycut delays hideApp and fakeCommandV until the release has settled.
        // Keep that delay, then allow the destination to regain keyboard focus.
        cancelPendingPaste()
        let generation = pasteGeneration
        let target = pasteTarget
        let expectedChangeCount = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, generation == self.pasteGeneration else { return }
            self.hideBezel()
            NSApp.hide(nil)
            guard self.refreshAccessibilityStatus() else {
                self.pasteLog.error("Automatic paste blocked: macOS has not authorized event posting")
                self.notify("Clip copied. Allow ClipStak in System Settings → Privacy & Security → Accessibility to paste automatically.")
                return
            }
            guard let target, !target.isTerminated else {
                self.pasteLog.error("Automatic paste cancelled: no destination application")
                return
            }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostPID == target.processIdentifier || frontmostPID == ProcessInfo.processInfo.processIdentifier {
                target.activate(options: [])
            }
            self.completePaste(
                content: content,
                expectedChangeCount: expectedChangeCount,
                target: target,
                generation: generation,
                deadline: ProcessInfo.processInfo.systemUptime + 1
            )
        }
    }

    private func completePaste(
        content: ClipContent,
        expectedChangeCount: Int,
        target: NSRunningApplication,
        generation: Int,
        deadline: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, generation == self.pasteGeneration, !target.isTerminated else { return }
            let pasteboard = NSPasteboard.general
            guard ClipboardPolicy.canCompletePaste(
                expectedChangeCount: expectedChangeCount,
                currentChangeCount: pasteboard.changeCount,
                clipboardStillHoldsClip: ClipPasteboard.contains(content, on: pasteboard)
            ) else {
                self.pasteLog.notice("Automatic paste cancelled: clipboard changed")
                return
            }
            let action = PasteReadiness.action(
                targetPID: target.processIdentifier,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                clipStakPID: ProcessInfo.processInfo.processIdentifier,
                bezelIsKey: self.bezel.isKeyWindow || self.sheet.isKeyWindow,
                modifiers: self.hardwareModifiers()
            )
            switch action {
            case .paste:
                if postCommandVEvent() {
                    self.pasteLog.notice("Command-V posted to restored destination")
                } else {
                    self.pasteLog.error("Command-V could not be created")
                }
            case .cancel:
                self.pasteLog.notice("Automatic paste cancelled: destination changed")
                return
            case .wait:
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    self.pasteLog.error("Automatic paste timed out waiting for focus or modifier release")
                    return
                }
                self.completePaste(content: content, expectedChangeCount: expectedChangeCount,
                                   target: target, generation: generation, deadline: deadline)
            }
        }
    }

    private func writeToPasteboard(_ content: ClipContent) -> Bool {
        let pasteboard = NSPasteboard.general
        guard ClipPasteboard.write(content, to: pasteboard) else { return false }
        ownChangeCount = pasteboard.changeCount
        return true
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
            guard !self.store.paused, let content = ClipPasteboard.read(from: pasteboard) else { return }
            let front = NSWorkspace.shared.frontmostApplication
            let result = self.store.record(
                content: content,
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

    @discardableResult
    private func refreshAccessibilityStatus() -> Bool {
        // These are passive checks. Never ask macOS to show its consent prompt
        // on launch; an old TCC entry can remain enabled but reject a new signature.
        let accessibility = AXIsProcessTrusted()
        let posting = CGPreflightPostEventAccess()
        pasteLog.notice("Permission status: Accessibility=\(accessibility, privacy: .public), event posting=\(posting, privacy: .public)")
        if !posting {
            statusItem.button?.toolTip = "ClipStak — allow Accessibility to paste automatically"
        } else if history.lastError == nil {
            statusItem.button?.toolTip = "ClipStak — hold ⇧⌘V, release to paste"
        }
        return posting
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func notify(_ message: String) {
        let script = "display notification \"\(message)\" with title \"ClipStak\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

private func postCommandVEvent() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
    let key = CGKeyCode(kVK_ANSI_V)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
    // 0x8 is the physical Command key. Some apps ignore a chord that only sets the symbolic flag.
    // Match Flycut's fakeKey: set Command on key-down only.
    down.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
    up.flags = []
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
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
