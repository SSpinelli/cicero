import AppKit

/// The face of the dictation HUD: a dark translucent pill that shows the user's
/// voice while they speak, and closes a laurel wreath around a single word once
/// the app takes the work over.
///
/// The division of labour is the whole design. While you hold the key the pill
/// carries nothing but your voice — no wreath, no caption, because neither
/// would tell you anything the moving bars don't. When you let go, the voice
/// settles, two laurel branches curl in from the edges, and the word for what
/// the app is doing appears between them. The wreath closing *is* the progress
/// indicator; Rome shows up where it earns its place instead of decorating
/// every frame.
final class HUDView: NSView {

    /// Recent loudness readings, oldest first, each roughly 0...1.
    var levels: [CGFloat] = [] { didSet { needsDisplay = true } }

    /// 0 while listening, 1 when the wreath is fully closed. `HUDWindow` eases
    /// this so the branches curl rather than snap.
    var close: CGFloat = 0 { didSet { needsDisplay = true } }

    /// Shown only when there is something words can say that the drawing
    /// cannot — which is every state except recording.
    var caption: String? { didSet { needsDisplay = true } }

    /// Tints the branches and the caption: laurel while working, bronze for a
    /// notice, terracotta on failure.
    var accent: NSColor = Palette.laurelOnDark { didSet { needsDisplay = true } }

    /// Whether the caption takes the accent color too. Normally it does not:
    /// the branches already carry the color, and a tinted word beside them is
    /// one signal too many. A failure is the exception — there the message is
    /// the point.
    var tintsCaption = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    private enum Metrics {
        /// How far the branches sit from the centre, as a share of the width.
        static let branchInset: CGFloat = 0.30
        static let barCount = 18
        /// The voice spans this much of the pill open, and this much closed —
        /// it yields the space the branches move into.
        static let voiceSpanOpen: CGFloat = 0.80
        static let voiceSpanClosed: CGFloat = 0.46
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        drawGround(r)

        // Absent while listening, so the recording state stays clean.
        if close > 0.01 {
            let inset = r.width * Metrics.branchInset
            drawBranch(centerX: r.midX - inset, in: r, mirrored: true)
            drawBranch(centerX: r.midX + inset, in: r, mirrored: false)
        }

        if let caption {
            draw(caption: caption, in: r)
        } else {
            drawVoice(in: r)
        }
    }

    /// A dark translucent pill with a hairline of light along its edge — the
    /// shape macOS uses for transient overlays, so Cicero sits on the desktop
    /// like something that belongs there.
    private func drawGround(_ r: NSRect) {
        let body = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(calibratedWhite: 0.09, alpha: 0.74).setFill()
        body.fill()

        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        edge.lineWidth = 1
        edge.stroke()
    }

    /// Half a wreath: a bezier stem with leaves fanning away from it.
    ///
    /// `mirrored` negates the x component of the stem's bulge and of every leaf
    /// direction, and nothing else. Mirroring only the leaf direction — flipping
    /// by `.pi` while leaving the fan tilt alone — leaves the two branches
    /// opening in different directions, which reads as a mistake rather than as
    /// a pair.
    private func drawBranch(centerX: CGFloat, in r: NSRect, mirrored: Bool) {
        // The branches fade in as they curl, so they arrive with the closing
        // rather than popping into an empty pill.
        let color = accent.withAlphaComponent(min(1, close * 1.4))
        color.setFill()
        color.setStroke()

        let sign: CGFloat = mirrored ? -1 : 1
        let height = r.height * 0.60
        let top = CGPoint(x: centerX, y: r.midY + height / 2)
        let bottom = CGPoint(x: centerX, y: r.midY - height / 2)
        // Nearly straight while open; curling inward to cradle the caption.
        let bulge = sign * height * (0.06 + 0.20 * close)
        let c1 = CGPoint(x: centerX + bulge, y: r.midY + height * 0.26)
        let c2 = CGPoint(x: centerX + bulge, y: r.midY - height * 0.26)

        let stem = NSBezierPath()
        stem.move(to: top)
        stem.curve(to: bottom, controlPoint1: c1, controlPoint2: c2)
        stem.lineWidth = 1.3
        stem.lineCapStyle = .round
        stem.stroke()

        let leaves = 5
        for i in 0..<leaves {
            let t = (CGFloat(i) + 0.5) / CGFloat(leaves)
            let anchor = cubic(t, top, c1, c2, bottom)
            // Leaves fan along the stem, always outward. `.pi - tilt` is the
            // mirror of `tilt`: it negates cosine and preserves sine, which is
            // exactly a reflection across the vertical axis.
            let tilt = (t - 0.5) * 0.7
            let direction = sign > 0 ? tilt : .pi - tilt
            leaf(at: anchor, direction: direction,
                 length: height * 0.26 * (1 - close * 0.25),
                 width: height * 0.075).fill()
        }
    }

    /// The voice, drawn symmetric about the centre line and tapering toward the
    /// ends so it reads as one form rather than a row of ticks.
    private func drawVoice(in r: NSRect) {
        Palette.tyrianOnDark.setFill()
        let count = Metrics.barCount
        let span = r.width * (Metrics.voiceSpanOpen
            - (Metrics.voiceSpanOpen - Metrics.voiceSpanClosed) * close)
        let slot = span / CGFloat(count)
        let barWidth = slot * 0.34
        let x0 = r.midX - span / 2
        // The bars also shrink as the wreath closes, so the voice settles
        // instead of being covered.
        let amplitude = 1 - close * 0.65

        for i in 0..<count {
            // Oldest reading on the left, so the voice scrolls the way it was
            // spoken. Missing readings draw as the resting minimum.
            let index = levels.count - count + i
            let level = index >= 0 && index < levels.count ? levels[index] : 0
            let falloff = 1 - pow(abs(CGFloat(i) - CGFloat(count - 1) / 2)
                / (CGFloat(count) / 2), 2) * 0.4
            let height = max(2, r.height * 0.46 * amplitude * level * falloff)
            let rect = NSRect(x: x0 + slot * CGFloat(i) + (slot - barWidth) / 2,
                              y: r.midY - height / 2,
                              width: barWidth, height: height)
            NSBezierPath(roundedRect: rect,
                         xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func draw(caption: String, in r: NSRect) {
        // The gap between the two stems — `branchInset` is measured from the
        // centre, so the span between them is twice it — less a little
        // clearance. This is all the caption may occupy: anything wider does
        // not merely "look cramped", it draws straight over the laurel and out
        // past the edge of the pill onto the desktop.
        let available = r.width * Metrics.branchInset * 2 - 12
        let text = headline(of: caption).uppercased()

        // Letterspaced caps: how Rome wrote on stone, and legible at a glance.
        // A long message matters more than the letterspacing does, so drop to
        // the tighter size before giving anything else up.
        var attributed = letterspaced(text, size: 11, kern: 2.0)
        if attributed.size().width > available {
            attributed = letterspaced(text, size: 9, kern: 0.6)
        }

        let size = attributed.size()
        guard size.width > available else {
            // The trailing letter carries a kern it has no successor to space
            // from; subtracting it keeps the text optically centred between the
            // branches.
            let kern = (attributed.attribute(.kern, at: 0, effectiveRange: nil)
                as? CGFloat) ?? 0
            attributed.draw(at: NSPoint(x: r.midX - (size.width - kern) / 2,
                                        y: r.midY - size.height / 2))
            return
        }

        // Too wide for one line. The pill is tall enough for two, and every
        // failure message the engine produces fits in them — so wrap before
        // giving any of the message up.
        let wrapped = paragraphed(attributed, breaking: .byWordWrapping)
        let needed = wrapped.boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        // Two line heights plus leading lands near 2.2; three near 3.2. The
        // threshold sits between them rather than exactly on two, so ordinary
        // line spacing doesn't push a two-line message into truncation.
        guard needed.height > size.height * 2.5 else {
            draw(wrapped, height: needed.height, available: available, in: r)
            return
        }

        // Longer than two lines will hold. Truncate rather than overflow: the
        // HUD is a glance, and the whole message stays in the menu bar for
        // anyone who wants to read it.
        draw(paragraphed(attributed, breaking: .byTruncatingTail),
             height: size.height, available: available, in: r)
    }

    /// The first sentence of a message.
    ///
    /// Failure messages are written as a headline followed by a detail — "Não
    /// ouvi nada. O microfone está mudo ou muito distante?" — because the menu
    /// bar has room for both. The HUD does not: the whole thing needs three
    /// wrapped lines, and a three-line paragraph in a dictation pill is worse
    /// than useless. The headline alone says what happened; the detail stays
    /// one click away in the menu.
    private func headline(of message: String) -> String {
        guard let end = message.firstIndex(where: { ".!?".contains($0) }) else {
            return message
        }
        let first = message[..<end]
        // A sentence too short to stand alone is probably an abbreviation or a
        // decimal, not the end of the thought — keep the whole message.
        return first.count >= 8 ? String(first) : message
    }

    private func draw(_ text: NSAttributedString, height: CGFloat,
                      available: CGFloat, in r: NSRect) {
        text.draw(in: NSRect(x: r.midX - available / 2,
                             y: r.midY - height / 2,
                             width: available, height: height))
    }

    private func letterspaced(_ text: String, size: CGFloat,
                              kern: CGFloat) -> NSAttributedString {
        let font = NSFont(name: "Optima", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .medium)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: captionColor,
            .kern: kern,
        ])
    }

    private func paragraphed(_ text: NSAttributedString,
                             breaking mode: NSLineBreakMode) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = mode
        paragraph.alignment = .center
        let copy = NSMutableAttributedString(attributedString: text)
        copy.addAttribute(.paragraphStyle, value: paragraph,
                          range: NSRange(location: 0, length: copy.length))
        return copy
    }

    private var captionColor: NSColor {
        tintsCaption ? accent : NSColor(calibratedWhite: 0.92, alpha: 0.85)
    }

    // MARK: - Geometry

    private func cubic(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint,
                       _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let m = 1 - t
        return CGPoint(
            x: m*m*m*p0.x + 3*m*m*t*p1.x + 3*m*t*t*p2.x + t*t*t*p3.x,
            y: m*m*m*p0.y + 3*m*m*t*p1.y + 3*m*t*t*p2.y + t*t*t*p3.y)
    }

    /// An almond: pointed where it meets the stem, pointed at the tip, widest
    /// in the middle.
    private func leaf(at anchor: CGPoint, direction: CGFloat,
                      length: CGFloat, width: CGFloat) -> NSBezierPath {
        let side = direction + .pi / 2
        func point(_ f: CGFloat, _ offset: CGFloat) -> CGPoint {
            CGPoint(x: anchor.x + cos(direction) * length * f + cos(side) * offset,
                    y: anchor.y + sin(direction) * length * f + sin(side) * offset)
        }
        let tip = CGPoint(x: anchor.x + cos(direction) * length,
                          y: anchor.y + sin(direction) * length)
        let path = NSBezierPath()
        path.move(to: anchor)
        path.curve(to: tip, controlPoint1: point(0.28, width), controlPoint2: point(0.72, width))
        path.curve(to: anchor, controlPoint1: point(0.72, -width), controlPoint2: point(0.28, -width))
        return path
    }
}
