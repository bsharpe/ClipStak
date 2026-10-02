import AppKit
import ClipStakCore

/// The dark card Flycut calls the bezel. It can take keys without activating ClipStak,
/// so the app underneath stays the paste target.
final class BezelPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    var onFlags: ((NSEvent) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
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

        let root = BezelView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        onKey?(event)
    }

    override func flagsChanged(with event: NSEvent) {
        onFlags?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    func placeOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let area = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2
        ))
    }

    func show(clip: Clip?, position: String, hint: String) {
        update(clip: clip, position: position, hint: hint)
        placeOnMouseScreen()
        alphaValue = 0
        // Use the same nonactivating panel presentation as Flycut.
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func update(clip: Clip?, position: String, hint: String) {
        (contentView as? BezelView)?.update(clip: clip, position: position, hint: hint)
    }
}

private final class BezelView: NSView {
    private let icon = NSImageView()
    private let appLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let imagePreview = NSImageView()
    private let positionLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyBezelBackground(to: self)

        icon.imageScaling = .scaleProportionallyUpOrDown
        imagePreview.imageScaling = .scaleProportionallyUpOrDown
        imagePreview.isHidden = true
        for label in [appLabel, dateLabel, body, positionLabel, hintLabel] {
            label.textColor = .white
            label.drawsBackground = false
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
        }
        body.maximumNumberOfLines = 10
        body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = 468
        body.font = .systemFont(ofSize: 16)
        body.cell?.wraps = true
        body.cell?.isScrollable = false
        appLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.alignment = .right
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        positionLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        hintLabel.alignment = .center

        for view in [icon, appLabel, dateLabel, body, imagePreview, positionLabel, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            appLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            appLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dateLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: appLabel.trailingAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            imagePreview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            imagePreview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imagePreview.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            imagePreview.bottomAnchor.constraint(equalTo: positionLabel.topAnchor, constant: -8),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            positionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            positionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            positionLabel.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -2),
            body.bottomAnchor.constraint(lessThanOrEqualTo: positionLabel.topAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawPiping(in: bounds)
    }

    func update(clip: Clip?, position: String, hint: String) {
        imagePreview.image = nil
        imagePreview.isHidden = true
        body.isHidden = false
        if let clip {
            if let image = clip.image, let thumbnail = image.thumbnail(maxPixelSize: 936) {
                imagePreview.image = NSImage(cgImage: thumbnail, size: .zero)
                imagePreview.setAccessibilityLabel(image.title)
                imagePreview.isHidden = false
                body.isHidden = true
                body.stringValue = ""
            } else {
                body.stringValue = clip.image?.title ?? String(clip.text.prefix(ClipStore.bezelPreviewLength))
            }
            appLabel.stringValue = clip.appName.isEmpty ? "Clipboard" : clip.appName
            dateLabel.stringValue = clipAgeFormatter.localizedString(for: clip.copiedAt, relativeTo: Date())
            if let path = clip.bundlePath {
                icon.image = NSWorkspace.shared.icon(forFile: path)
            } else {
                icon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            }
        } else {
            body.stringValue = "Nothing copied yet"
            appLabel.stringValue = ""
            dateLabel.stringValue = ""
            icon.image = nil
        }
        positionLabel.stringValue = position
        hintLabel.stringValue = hint
    }
}

/// The dark translucent card shared by the bezel and the contact sheet.
func applyBezelBackground(to view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.82).cgColor
    view.layer?.cornerRadius = 22
}

/// Upholstery piping in the app icon's red. The cord is drawn as nested strokes shaded like a
/// lit cylinder: dark at the rim, the icon red on its flank, a soft highlight on the ridge.
func drawPiping(in bounds: NSRect) {
    let seam = NSBezierPath(roundedRect: bounds.insetBy(dx: 9.5, dy: 9.5), xRadius: 12.5, yRadius: 12.5)
    seam.lineWidth = 1.5
    NSColor(white: 0, alpha: 0.4).setStroke()
    seam.stroke()

    let red = NSColor(srgbRed: 0.86, green: 0.16, blue: 0.18, alpha: 1)
    let rim = NSColor(srgbRed: 0.36, green: 0.03, blue: 0.05, alpha: 1)
    let cord = NSBezierPath(roundedRect: bounds.insetBy(dx: 4.5, dy: 4.5), xRadius: 17.5, yRadius: 17.5)
    for step in 0..<12 {
        let angle = CGFloat.pi / 2 * CGFloat(12 - step) / 12
        let light = cos(angle)
        let path = cord.copy() as! NSBezierPath
        path.transform(using: AffineTransform(translationByX: 0, byY: light))
        path.lineWidth = 9 * sin(angle)
        let color = light < 0.75
            ? rim.blended(withFraction: light / 0.75, of: red)
            : red.blended(withFraction: (light - 0.75) / 0.25 * 0.3, of: .white)
        color?.setStroke()
        path.stroke()
    }
}

/// "5 minutes ago", "yesterday", "last week".
let clipAgeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
}()
