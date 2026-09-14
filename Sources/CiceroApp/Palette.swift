import AppKit

/// Cicero's brand colors: Roman marble and imperial purple.
public enum Palette {
    public static let marble = NSColor(srgbRed: 0xF4 / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)
    public static let tyrianPurple = NSColor(srgbRed: 0x6B / 255, green: 0x2D / 255, blue: 0x4F / 255, alpha: 1)
    public static let laurel = NSColor(srgbRed: 0x6B / 255, green: 0x7A / 255, blue: 0x4F / 255, alpha: 1)
    public static let bronze = NSColor(srgbRed: 0xC9 / 255, green: 0xA2 / 255, blue: 0x27 / 255, alpha: 1)
    public static let basalt = NSColor(srgbRed: 0x1C / 255, green: 0x1A / 255, blue: 0x19 / 255, alpha: 1)

    /// The same two brand colors lightened for use on a dark ground. Tyrian
    /// purple and laurel green are both dark enough that on the HUD's basalt
    /// pill they read as smudges rather than as color.
    public static let tyrianOnDark = NSColor(srgbRed: 0xA8 / 255, green: 0x6D / 255, blue: 0x9A / 255, alpha: 1)
    public static let laurelOnDark = NSColor(srgbRed: 0x9C / 255, green: 0xAD / 255, blue: 0x82 / 255, alpha: 1)
    /// Failures, in a red muted enough to sit beside the brand colors.
    public static let terracotta = NSColor(srgbRed: 0xD9 / 255, green: 0x6B / 255, blue: 0x63 / 255, alpha: 1)

    public static let tagline = "Verba volant, scripta manent"
}
