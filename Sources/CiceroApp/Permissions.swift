import AVFoundation
import AppKit
// `kAXTrustedCheckOptionPrompt` is imported from C as a global `var`, which
// Swift 6's strict concurrency checking flags as unsafe shared mutable state
// wherever it's read — it's a system-published constant in practice, so
// `@preconcurrency` here accepts that once for the whole file rather than
// needing a suppression at the call site.
@preconcurrency import ApplicationServices

enum Permissions {

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt pointing the user at Accessibility settings.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openSettings(_ pane: SettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    enum SettingsPane {
        case accessibility
        case microphone

        var urlString: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            }
        }
    }
}
