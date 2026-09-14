import AppKit

/// Cicero's menu bar mark: an open ring, the C of the name.
///
/// Drawn rather than taken from SF Symbols because the closest symbol,
/// `laurel.leading`, renders 9 points wide — a thin half-wreath that is
/// genuinely hard to pick out of a crowded menu bar, which is how this app
/// shipped with an icon its own author could not find.
///
/// The design brief called for a C formed from a laurel wreath. At 18 points
/// that does not survive: leaves either merge into lumps on the stroke or
/// vanish. The letterform carries the identity on its own here, and the wreath
/// is left for a hand-drawn vector rather than faked procedurally.
///
/// Returned as a template image, so AppKit tints it for light and dark menu
/// bars without the app tracking the theme.
enum MenuBarIcon {

    /// Built with `NSImage(size:flipped:drawingHandler:)` rather than
    /// `lockFocus()`. The handler is re-invoked whenever AppKit needs the mark
    /// again — a different backing scale, a theme change, a status bar
    /// redraw — where a `lockFocus` image is rasterised once at creation and
    /// can come out empty depending on the context that happened to be current.
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size),
                            flipped: false) { _ in
            draw(size: size)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(size: CGFloat) {
        NSColor.black.setStroke()
        let center = CGPoint(x: size / 2, y: size / 2)
        // Sized to fill the 18pt box the way system symbols do. The first
        // attempt used radius 0.27 and a 0.085 stroke, which left the mark
        // occupying about 11 of the 18 points and reading as a faint speck
        // next to its neighbours.
        let radius = size * 0.33
        // The opening faces right. 105° is wide enough to read as a C rather
        // than a nicked ring, without the arc looking like a broken circle.
        let gap: CGFloat = 105

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center,
                      radius: radius,
                      startAngle: gap / 2,
                      endAngle: 360 - gap / 2,
                      clockwise: false)
        arc.lineWidth = size * 0.115
        arc.lineCapStyle = .round
        arc.stroke()
    }
}
