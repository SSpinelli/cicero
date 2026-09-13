import Foundation
@testable import CiceroKit

/// Thread-safe recorder of calls, so fakes stay Sendable under strict concurrency.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    /// Holds the lock across a read-modify-write so concurrent mutations
    /// (e.g. appending to an array) can't interleave and lose an update.
    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}

struct FakeRecorder: AudioRecorder {
    let buffer: AudioBuffer
    let startError: CiceroError?
    let started = Box(false)
    let startCount = Box(0)
    let cancelled = Box(false)

    init(buffer: AudioBuffer = AudioBuffer(samples: Array(repeating: 0.3, count: 16_000), sampleRate: 16_000),
         startError: CiceroError? = nil) {
        self.buffer = buffer
        self.startError = startError
    }

    func start() async throws {
        startCount.mutate { $0 += 1 }
        if let startError { throw startError }
        started.value = true
    }
    func stop() async throws -> AudioBuffer { buffer }
    func cancel() async { cancelled.value = true }
}

struct FakeTranscriber: Transcriber {
    let result: String
    let error: CiceroError?
    init(result: String = "olá tipo isso é um teste", error: CiceroError? = nil) {
        self.result = result
        self.error = error
    }
    func transcribe(_ audio: AudioBuffer) async throws -> String {
        if let error { throw error }
        return result
    }
}

struct FakePolisher: TextPolisher {
    let result: String
    let error: CiceroError?
    let receivedContext = Box(DictationContext.unknown)
    init(result: String = "Olá, isso é um teste.", error: CiceroError? = nil) {
        self.result = result
        self.error = error
    }
    func polish(_ text: String, context: DictationContext) async throws -> String {
        receivedContext.value = context
        if let error { throw error }
        return result
    }
}

struct FakeInserter: TextInserter {
    let error: CiceroError?
    let inserted = Box<[String]>([])
    init(error: CiceroError? = nil) { self.error = error }
    func insert(_ text: String) async throws {
        if let error { throw error }
        inserted.mutate { $0.append(text) }
    }
}

struct FakeContextProvider: ContextProvider {
    let context: DictationContext
    init(context: DictationContext = DictationContext(appName: "Mail", bundleIdentifier: "com.apple.mail")) {
        self.context = context
    }
    func currentContext() async -> DictationContext { context }
}
