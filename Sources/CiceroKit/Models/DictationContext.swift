/// Describes the app that was frontmost when dictation started, so the
/// polisher can match its tone to the destination.
public struct DictationContext: Sendable, Equatable {
    public let appName: String?
    public let bundleIdentifier: String?

    public init(appName: String?, bundleIdentifier: String?) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }

    public static let unknown = DictationContext(appName: nil, bundleIdentifier: nil)
}
