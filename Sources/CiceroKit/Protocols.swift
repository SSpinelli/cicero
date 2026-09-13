public protocol AudioRecorder: Sendable {
    func start() async throws
    func stop() async throws -> AudioBuffer
    func cancel() async
}

public protocol Transcriber: Sendable {
    func transcribe(_ audio: AudioBuffer) async throws -> String
}

public protocol TextPolisher: Sendable {
    func polish(_ text: String, context: DictationContext) async throws -> String
}

public protocol TextInserter: Sendable {
    func insert(_ text: String) async throws
}

public protocol ContextProvider: Sendable {
    func currentContext() async -> DictationContext
}
