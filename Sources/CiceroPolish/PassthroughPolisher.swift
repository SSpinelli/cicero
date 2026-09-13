import CiceroKit

/// Returns the transcript untouched. Used whenever the on-device model is
/// unavailable, so dictation keeps working with raw text.
public struct PassthroughPolisher: TextPolisher {
    public init() {}

    public func polish(_ text: String, context: DictationContext) async throws -> String {
        text
    }
}
