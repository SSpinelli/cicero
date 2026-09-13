public enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case polishing
    case inserting
    case failed(String)
}
