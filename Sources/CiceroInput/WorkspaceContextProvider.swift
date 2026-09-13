import AppKit
import CiceroKit

/// Reports which app is frontmost, so the polisher can match its tone.
public struct WorkspaceContextProvider: ContextProvider {
    public init() {}

    public func currentContext() async -> DictationContext {
        await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return DictationContext(appName: app?.localizedName,
                                    bundleIdentifier: app?.bundleIdentifier)
        }
    }
}
