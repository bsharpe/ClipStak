import AppKit
import Carbon.HIToolbox
import ClipStakCore

private enum Sheet {
    static let cell = NSSize(width: 200, height: 140)
    static let gap: CGFloat = 12
    /// Keeps the grid clear of the piping.
    static let padding: CGFloat = 26
    static let footer: CGFloat = 30
    static let hintBottom: CGFloat = 16
}

/// All clips in a grid. Like the bezel it takes keys without activating ClipStak,
/// so the app underneath stays the paste target.
final class ContactSheetPanel: NSPanel {
    var onChoose: ((Int) -> Void)?
    var onClose: (() -> Void)?
    private let grid = SheetGridView()
    private let scrollView = NSScrollView()
    private let hint = NSTextField(labelWithString: "click or return to paste  ·  arrows move  ·  esc closes")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none

        let root = SheetView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = grid
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.55)
        hint.alignment = .center
        root.addSubview(scrollView)
        root.addSubview(hint)
        contentView = root
        grid.onClick = { [weak self] index in self?.onChoose?(index) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_LeftArrow: move(.left)
        case kVK_RightArrow: move(.right)
        case kVK_UpArrow: move(.up)
        case kVK_DownArrow: move(.down)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !grid.clips.isEmpty { onChoose?(grid.selected) }
        case kVK_Escape: onClose?()
        default: break
        }
    }

    func show(clips: [Clip], selected: Int) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let area = screen.visibleFrame
        let step = NSSize(width: Sheet.cell.width + Sheet.gap, height: Sheet.cell.height + Sheet.gap)
        let columns = min(max(Int((area.width - 120 - 2 * Sheet.padding + Sheet.gap) / step.width), 2), 5)
        let rows = max((clips.count + columns - 1) / columns, 1)
        let visibleRows = min(rows, max(1, Int((area.height - 160) / step.height)))
        let gridWidth = CGFloat(columns) * step.width - Sheet.gap
        let viewHeight = CGFloat(visibleRows) * step.height - Sheet.gap
        let size = NSSize(
            width: gridWidth + 2 * Sheet.padding,
            height: Sheet.hintBottom + Sheet.footer + viewHeight + Sheet.padding
        )
        setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: false)

        grid.load(clips: clips, selected: selected, columns: columns)
        grid.frame = NSRect(x: 0, y: 0, width: gridWidth, height: CGFloat(rows) * step.height - Sheet.gap)
        scrollView.frame = NSRect(x: Sheet.padding, y: Sheet.hintBottom + Sheet.footer, width: gridWidth, height: viewHeight)
        hint.frame = NSRect(x: Sheet.padding, y: Sheet.hintBottom, width: gridWidth, height: 16)
        grid.scroll(.zero)
        revealSelection()

        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    private func move(_ direction: SheetNavigation.Direction) {
        grid.selected = SheetNavigation.move(direction, from: grid.selected, columns: grid.columns, count: grid.clips.count)
        grid.needsDisplay = true
        revealSelection()
    }

    private func revealSelection() {
        guard !grid.clips.isEmpty else { return }
        grid.scrollToVisible(grid.cellRect(grid.selected).insetBy(dx: 0, dy: -Sheet.gap))
    }
}

private final class SheetView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyBezelBackground(to: self)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawPiping(in: bounds)
    }
}

/// Draws every cell itself; a grid of 40 subviews would be heavier and gain nothing.
private final class SheetGridView: NSView {
    private(set) var clips: [Clip] = []
    private(set) var columns = 1
    var selected = 0
    var onClick: ((Int) -> Void)?
    private var icons: [NSImage] = []
    private var thumbnails: [Int: NSImage] = [:]

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func load(clips: [Clip], selected: Int, columns: Int) {
        self.clips = clips
        self.columns = columns
        self.selected = clips.isEmpty ? 0 : min(max(selected, 0), clips.count - 1)
        let fallback = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white])) ?? NSImage()
        icons = clips.map { clip in clip.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) } ?? fallback }
        thumbnails = [:]
        for (index, clip) in clips.enumerated() {
            if let thumbnail = clip.image?.thumbnail(maxPixelSize: 400) {
                thumbnails[index] = NSImage(cgImage: thumbnail, size: .zero)
            }
        }
        needsDisplay = true
    }

    func cellRect(_ index: Int) -> NSRect {
        NSRect(
            x: CGFloat(index % columns) * (Sheet.cell.width + Sheet.gap),
            y: CGFloat(index / columns) * (Sheet.cell.height + Sheet.gap),
            width: Sheet.cell.width,
            height: Sheet.cell.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = clips.indices.first(where: { cellRect($0).contains(point) }) {
            onClick?(index)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !clips.isEmpty else {
            let empty = NSAttributedString(string: "Nothing copied yet", attributes: [
                .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white,
            ])
            let size = empty.size()
            empty.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }
        for index in clips.indices where cellRect(index).intersects(dirtyRect) {
            drawCell(index)
        }
    }

    private func drawCell(_ index: Int) {
        let clip = clips[index]
        let rect = cellRect(index)
        let isSelected = index == selected
        NSColor.white.withAlphaComponent(isSelected ? 0.12 : 0.06).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        if isSelected {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25), xRadius: 10.75, yRadius: 10.75)
            ring.lineWidth = 2.5
            NSColor(srgbRed: 0.86, green: 0.16, blue: 0.18, alpha: 1).setStroke()
            ring.stroke()
        }

        let inner = rect.insetBy(dx: 10, dy: 10)
        icons[index].draw(in: NSRect(x: inner.minX, y: inner.minY, width: 16, height: 16), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let age = NSAttributedString(
            string: clipAgeFormatter.localizedString(for: clip.copiedAt, relativeTo: Date()),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        )
        let ageWidth = ceil(age.size().width)
        age.draw(at: NSPoint(x: inner.maxX - ageWidth, y: inner.minY + 1))
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: clip.appName.isEmpty ? "Clipboard" : clip.appName, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: truncating,
        ]).draw(in: NSRect(x: inner.minX + 22, y: inner.minY + 1, width: inner.width - 28 - ageWidth, height: 15))

        let body = NSRect(x: inner.minX, y: inner.minY + 24, width: inner.width, height: inner.height - 24)
        if let thumbnail = thumbnails[index] {
            let scale = min(body.width / thumbnail.size.width, body.height / thumbnail.size.height, 1)
            let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
            thumbnail.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let wrapping = NSMutableParagraphStyle()
            wrapping.lineBreakMode = .byWordWrapping
            // A cell shows a few lines; never lay out a megabyte of text to find them.
            NSAttributedString(string: clip.image?.title ?? String(clip.text.prefix(400)), attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white, .paragraphStyle: wrapping,
            ]).draw(with: body, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
