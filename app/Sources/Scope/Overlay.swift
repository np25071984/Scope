// The switcher overlay: a vertical list of app icons and window titles.
//
// A borderless, non-activating panel that ignores the mouse. The pointer is
// handled by KeyTap's hit-testing instead, the way the Lua version did it,
// because a panel that took clicks could take focus from the window the click
// is about to hand it to.

import AppKit

final class Overlay {
    struct Row {
        let title: String
        let app: String
        let icon: NSImage?
    }

    static let rowHeight: CGFloat = 54
    static let iconSize: CGFloat = 36
    static let padding: CGFloat = 10
    static let width: CGFloat = 620
    static let radius: CGFloat = 16

    private let panel: NSPanel
    private let view = RowsView()

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = view
    }

    /// Shows the rows centred on `screen`. Returns the panel's frame in global
    /// top-left coordinates, for hit-testing pointer events.
    func show(_ rows: [Row], selected: Int, on screen: NSScreen) -> CGRect {
        view.rows = rows
        view.selected = selected

        let height = Self.padding * 2 + CGFloat(rows.count) * Self.rowHeight
        let area = screen.visibleFrame
        let frame = NSRect(
            x: (area.midX - Self.width / 2).rounded(),
            y: (area.midY - height / 2).rounded(),
            width: Self.width, height: height)
        panel.setFrame(frame, display: false)
        view.needsDisplay = true
        panel.orderFrontRegardless()

        let primary = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height)
    }

    func select(_ row: Int) {
        guard view.selected != row else { return }
        view.selected = row
        view.needsDisplay = true
    }

    func hide() {
        panel.orderOut(nil)
        view.rows = []
    }
}

private final class RowsView: NSView {
    var rows: [Overlay.Row] = []
    var selected = 0

    override var isFlipped: Bool { true }

    private static let backdrop = NSColor(white: 0.09, alpha: 0.94)
    private static let border = NSColor(white: 1, alpha: 0.13)
    private static let highlight = NSColor(srgbRed: 0.29, green: 0.40, blue: 0.90, alpha: 0.90)

    private static func attributes(size: CGFloat, alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .paragraphStyle: style,
        ]
    }
    private static let titleAttributes = attributes(size: 14, alpha: 0.98)
    private static let appAttributes = attributes(size: 11, alpha: 0.52)

    override func draw(_ dirtyRect: NSRect) {
        let pad = Overlay.padding, rowH = Overlay.rowHeight, icon = Overlay.iconSize

        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Overlay.radius, yRadius: Overlay.radius)
        Self.backdrop.setFill()
        outline.fill()
        Self.border.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        if rows.indices.contains(selected) {
            let y = pad + CGFloat(selected) * rowH
            Self.highlight.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: rowH),
                xRadius: 10, yRadius: 10
            ).fill()
        }

        let textX = pad + 12 + icon + 14
        let textW = bounds.width - textX - pad - 12
        for (i, row) in rows.enumerated() {
            let y = pad + CGFloat(i) * rowH
            row.icon?.draw(
                in: NSRect(x: pad + 12, y: y + (rowH - icon) / 2, width: icon, height: icon),
                from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
            (row.title as NSString).draw(
                with: NSRect(x: textX, y: y + 9, width: textW, height: 20),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: Self.titleAttributes)
            (row.app as NSString).draw(
                with: NSRect(x: textX, y: y + 29, width: textW, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: Self.appAttributes)
        }
    }
}
