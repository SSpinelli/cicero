# Cicero Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app where holding `⌃⌥Space`, speaking, and releasing inserts transcribed and polished text into the frontmost app, with everything running on-device.

**Architecture:** A pure, fully testable core (`CiceroKit`) holds the state machine and four protocols. Every side effect — microphone, keyboard, clipboard, ML models — lives in a separate module behind one of those protocols. `CiceroApp` is the only module that knows the concrete implementations and wires them together. This lets the entire dictation flow be tested with fakes, with no microphone and no model loaded.

**Tech Stack:** Swift 6.3, SwiftPM (no Xcode), AppKit + SwiftUI, AVFoundation, WhisperKit (CoreML), Apple FoundationModels, Swift Testing, CoreGraphics event taps.

**Spec:** [`docs/superpowers/specs/2026-09-12-cicero-design.md`](../specs/2026-09-12-cicero-design.md)

## Global Constraints

These apply to every task. Do not restate them per task; they are always in force.

- **Deployment target:** macOS 26.0. The machine runs macOS 26.6.2.
- **No Xcode.** Only Command Line Tools are installed. `xcodebuild` does not exist. Every build, test, and package step runs through `swift` CLI. Never write a step that requires Xcode.
- **Swift 6 strict concurrency** is enabled. All protocol types crossing module boundaries are `Sendable`.
- **Never run `swift test`. It silently does nothing on this machine.** SwiftPM compiles a `.xctest` bundle that only Xcode's `xctest` binary can load; without Xcode it builds, links, prints `Build complete!` and exits 0 **without running a single test**. A green `swift test` here is not evidence of anything.
  Tests are therefore **executable targets**, not test targets: each declares `@main` calling `Testing.__swiftPMEntryPoint()`, lives under `Tests/<Name>/` via an explicit `path:`, and is run with `swift run`. Always invoke them through **`./Scripts/test.sh [filter]`**, which runs every runner that exists and exits non-zero if any test fails. This was verified end to end: a deliberately failing expectation reports the failure and exits 1.
  The Swift Testing framework is not on the default search path for non-test targets under Command Line Tools, so each runner target needs the framework and rpath flags defined once in `Package.swift` (Task 1). Reuse that shared definition; never retype the paths.
- **Whisper model:** `large-v3-turbo`. Do not substitute a smaller model — the smaller fast ones are English-only and the user dictates mixed Portuguese and English.
- **Transcription language:** auto-detect. The user code-switches between pt-BR and English mid-sentence.
- **Default hotkey:** `⌃⌥Space` (control + option + space). Configurable, but this is the shipped default. Do not default to `fn`.
- **Text insertion:** clipboard swap + synthetic ⌘V. Not Accessibility text insertion.
- **Golden rule:** never lose what the user said. Every failure path must either still insert the raw text or keep it retrievable. A failure must never silently discard a transcript.
- **App type:** menu bar only. `Info.plist` sets `LSUIElement = true` (no Dock icon).
- **Palette** (exact hex values): Marble `#F4F1EA`, Tyrian Purple `#6B2D4F`, Laurel `#6B7A4F`, Bronze `#C9A227`, Basalt `#1C1A19`.
- **Tagline** (exact text): `Verba volant, scripta manent`.
- **Language of user-facing strings:** Portuguese (pt-BR).
- **Commit after every task.** Small, frequent commits.

---

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Targets, dependencies, platform floor |
| `Sources/CiceroKit/Models/AudioBuffer.swift` | PCM samples + silence detection |
| `Sources/CiceroKit/Models/DictationState.swift` | State enum |
| `Sources/CiceroKit/Models/DictationContext.swift` | Frontmost app info |
| `Sources/CiceroKit/Models/CiceroError.swift` | Typed errors |
| `Sources/CiceroKit/Protocols.swift` | The four ports + context provider |
| `Sources/CiceroKit/DictationEngine.swift` | State machine and orchestration |
| `Sources/CiceroAudio/MicrophoneRecorder.swift` | AVAudioEngine → 16 kHz mono Float |
| `Sources/CiceroWhisper/WhisperKitTranscriber.swift` | WhisperKit adapter |
| `Sources/CiceroPolish/TextChunker.swift` | Sentence-boundary splitting (pure) |
| `Sources/CiceroPolish/PassthroughPolisher.swift` | No-op fallback polisher |
| `Sources/CiceroPolish/FoundationModelsPolisher.swift` | Apple on-device LLM adapter |
| `Sources/CiceroInput/HotkeyMatcher.swift` | Pure keycode/flag matching |
| `Sources/CiceroInput/HotkeyMonitor.swift` | CGEventTap wiring |
| `Sources/CiceroInput/ClipboardTextInserter.swift` | Clipboard swap + ⌘V |
| `Sources/CiceroInput/WorkspaceContextProvider.swift` | Frontmost app lookup |
| `Sources/CiceroApp/main.swift` | Entry point |
| `Sources/CiceroApp/AppDelegate.swift` | Composition root, menu bar |
| `Sources/CiceroApp/Permissions.swift` | Mic + Accessibility gating |
| `Sources/CiceroApp/HUDWindow.swift` | Floating dictation HUD |
| `Sources/CiceroApp/Palette.swift` | Brand colors |
| `Tests/CiceroKitTests/*` | Engine + model tests with fakes |
| `Tests/CiceroPolishTests/*` | Chunker + polisher tests |
| `Tests/CiceroInputTests/*` | Matcher + clipboard tests |
| `Tests/<Name>/Runner.swift` | One per test target: `@main` entry point into Swift Testing |
| `Scripts/test.sh` | Runs every test runner; optional filter argument |
| `Scripts/bundle.sh` | Build, assemble `Cicero.app`, sign |
| `Scripts/create-signing-identity.sh` | One-time stable self-signed cert |

---

### Task 1: Project scaffolding and domain models

Sets up the package and the value types the rest of the plan depends on. The only real logic here is silence detection, which the engine needs for the "empty audio inserts nothing" rule.

**Files:**
- Create: `.gitignore`
- Create: `Package.swift`
- Create: `Tests/CiceroKitTests/Runner.swift`
- Create: `Scripts/test.sh`
- Create: `Sources/CiceroKit/Models/AudioBuffer.swift`
- Create: `Sources/CiceroKit/Models/DictationState.swift`
- Create: `Sources/CiceroKit/Models/DictationContext.swift`
- Create: `Sources/CiceroKit/Models/CiceroError.swift`
- Test: `Tests/CiceroKitTests/AudioBufferTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `AudioBuffer(samples:sampleRate:)` with `.duration: TimeInterval` and `.isSilent(threshold: Float = 0.01) -> Bool`; `DictationState` enum with cases `idle`, `recording`, `transcribing`, `polishing`, `inserting`, `failed(String)`; `DictationContext(appName:bundleIdentifier:)` with static `.unknown`; `CiceroError` enum with cases `recordingFailed(String)`, `transcriptionFailed(String)`, `polishingFailed(String)`, `insertionBlockedBySecureInput`, `insertionFailed(String)`, `accessibilityNotGranted`, and a `userMessage` property.
- Produces (test harness every later task depends on): the `testRunnerSwiftSettings` and `testRunnerLinkerSettings` constants in `Package.swift`, the `Runner.swift` entry-point pattern, and `Scripts/test.sh`.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
.build/
.swiftpm/
*.xcodeproj
.DS_Store
Cicero.app/
dist/

# Agent scratch: SDD ledger, briefs, reports, review packages.
.superpowers/
.claude/worktrees/
```

- [ ] **Step 2: Create `Package.swift` and the test harness**

Only `CiceroKit` and its runner exist so far. Later tasks add targets to this same file and reuse the two settings constants defined here.

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

// Swift Testing ships with the Command Line Tools, but its framework is only on
// the search path for `testTarget`s — and a testTarget is useless on this
// machine, because running one requires Xcode's `xctest` binary. Test targets
// are therefore plain executables with an @main entry point, and they need
// these flags to find Swift Testing at compile time and load it at run time.
// Defined once here; every runner target reuses them.
let testingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingInteropLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let testRunnerSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-F", testingFrameworks])
]

let testRunnerLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-F", testingFrameworks,
        "-framework", "Testing",
        "-Xlinker", "-rpath", "-Xlinker", testingFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", testingInteropLibs,
    ])
]

let package = Package(
    name: "Cicero",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CiceroKit"),
        .executableTarget(
            name: "CiceroKitTests",
            dependencies: ["CiceroKit"],
            path: "Tests/CiceroKitTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
    ]
)
```

`Tests/CiceroKitTests/Runner.swift` — the entry point. Every test target gets one of these, identical but for the struct name. The file must not be called `main.swift`, which would make SwiftPM treat it as top-level code and conflict with `@main`.

```swift
import Testing

@main
struct CiceroKitTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
```

`Scripts/test.sh` — the only way tests are ever run in this project.

```bash
#!/usr/bin/env bash
# Runs every Cicero test runner. Optional first argument filters by test name.
#
# `swift test` is NOT usable on this machine: without Xcode there is no `xctest`
# binary to load the bundle SwiftPM builds, so it exits 0 having run nothing.
# The runners are executables instead, and this script drives them.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FILTER="${1:-}"
RUNNERS=(CiceroKitTests CiceroAudioTests CiceroWhisperTests CiceroPolishTests CiceroInputTests)

ran=0
failed=0
for runner in "${RUNNERS[@]}"; do
    [ -d "Tests/$runner" ] || continue
    ran=$((ran + 1))
    echo "── $runner"
    if [ -n "$FILTER" ]; then
        swift run "$runner" --filter "$FILTER" || failed=$((failed + 1))
    else
        swift run "$runner" || failed=$((failed + 1))
    fi
done

if [ "$ran" -eq 0 ]; then
    echo "Nenhum runner de teste encontrado." >&2
    exit 1
fi
if [ "$failed" -gt 0 ]; then
    echo "FALHOU: $failed de $ran runners." >&2
    exit 1
fi
echo "OK: $ran runner(s)."
```

Make it executable: `chmod +x Scripts/test.sh`

- [ ] **Step 3: Write the failing test**

Create `Tests/CiceroKitTests/AudioBufferTests.swift`:

```swift
import Testing
@testable import CiceroKit

@Suite("AudioBuffer")
struct AudioBufferTests {

    @Test("duration is samples divided by sample rate")
    func duration() {
        let buffer = AudioBuffer(samples: Array(repeating: 0.5, count: 16_000), sampleRate: 16_000)
        #expect(buffer.duration == 1.0)
    }

    @Test("an all-zero buffer is silent")
    func allZeroIsSilent() {
        let buffer = AudioBuffer(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)
        #expect(buffer.isSilent())
    }

    @Test("an empty buffer is silent")
    func emptyIsSilent() {
        let buffer = AudioBuffer(samples: [], sampleRate: 16_000)
        #expect(buffer.isSilent())
    }

    @Test("a loud buffer is not silent")
    func loudIsNotSilent() {
        let buffer = AudioBuffer(samples: Array(repeating: 0.4, count: 16_000), sampleRate: 16_000)
        #expect(!buffer.isSilent())
    }

    @Test("room tone below the threshold is silent")
    func roomToneIsSilent() {
        let buffer = AudioBuffer(samples: Array(repeating: 0.001, count: 16_000), sampleRate: 16_000)
        #expect(buffer.isSilent())
    }
}
```

- [ ] **Step 4: Run the test and verify it fails**

Run: `./Scripts/test.sh AudioBuffer`
Expected: FAIL — compile error, `cannot find 'AudioBuffer' in scope`.

- [ ] **Step 5: Write the domain models**

`Sources/CiceroKit/Models/AudioBuffer.swift`:

```swift
import Foundation

/// Mono PCM audio as normalized float samples in [-1, 1].
public struct AudioBuffer: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    /// Root-mean-square amplitude below `threshold` counts as silence.
    /// Guards against inserting text when the user tapped the hotkey by accident.
    public func isSilent(threshold: Float = 0.01) -> Bool {
        guard !samples.isEmpty else { return true }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        return rms < threshold
    }
}
```

`Sources/CiceroKit/Models/DictationState.swift`:

```swift
public enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case polishing
    case inserting
    case failed(String)
}
```

`Sources/CiceroKit/Models/DictationContext.swift`:

```swift
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
```

`Sources/CiceroKit/Models/CiceroError.swift`:

```swift
import Foundation

public enum CiceroError: Error, Equatable, Sendable {
    case recordingFailed(String)
    case transcriptionFailed(String)
    case polishingFailed(String)
    case insertionBlockedBySecureInput
    case insertionFailed(String)
    case accessibilityNotGranted

    public var userMessage: String {
        switch self {
        case .accessibilityNotGranted:
            return "Permissão de Acessibilidade necessária para o atalho global e para colar."
        case .recordingFailed(let detail):
            return "Não foi possível gravar: \(detail)"
        case .transcriptionFailed(let detail):
            return "Não foi possível transcrever: \(detail)"
        case .polishingFailed(let detail):
            return "Não foi possível polir o texto: \(detail)"
        case .insertionBlockedBySecureInput:
            return "Campo de senha em foco. O texto ficou disponível no menu."
        case .insertionFailed(let detail):
            return "Não foi possível colar: \(detail)"
        }
    }
}
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `./Scripts/test.sh AudioBuffer`
Expected: PASS, 5 tests.

- [ ] **Step 7: Commit**

```bash
git add .gitignore Package.swift Scripts Sources/CiceroKit Tests/CiceroKitTests
git commit -m "Add package scaffolding, test harness and CiceroKit domain models"
```

---

### Task 2: Dictation engine happy path

The state machine, driven entirely by fakes. This is the heart of the app and the only place the flow is orchestrated.

**Files:**
- Create: `Sources/CiceroKit/Protocols.swift`
- Create: `Sources/CiceroKit/DictationEngine.swift`
- Create: `Tests/CiceroKitTests/Fakes.swift`
- Test: `Tests/CiceroKitTests/DictationEngineTests.swift`

**Interfaces:**
- Consumes: `AudioBuffer`, `DictationState`, `DictationContext`, `CiceroError` from Task 1.
- Produces: protocols `AudioRecorder`, `Transcriber`, `TextPolisher`, `TextInserter`, `ContextProvider`; class `DictationEngine(recorder:transcriber:polisher:inserter:contextProvider:)` with `@MainActor` properties `state: DictationState` and `lastTranscript: String?`, and methods `startDictation() async`, `finishDictation() async`, `cancelDictation() async`.

- [ ] **Step 1: Write the protocols**

`Sources/CiceroKit/Protocols.swift`:

```swift
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
```

- [ ] **Step 2: Write the fakes**

`Tests/CiceroKitTests/Fakes.swift`:

```swift
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
}

struct FakeRecorder: AudioRecorder {
    let buffer: AudioBuffer
    let startError: CiceroError?
    let started = Box(false)
    let cancelled = Box(false)

    init(buffer: AudioBuffer = AudioBuffer(samples: Array(repeating: 0.3, count: 16_000), sampleRate: 16_000),
         startError: CiceroError? = nil) {
        self.buffer = buffer
        self.startError = startError
    }

    func start() async throws {
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
        inserted.value.append(text)
    }
}

struct FakeContextProvider: ContextProvider {
    let context: DictationContext
    init(context: DictationContext = DictationContext(appName: "Mail", bundleIdentifier: "com.apple.mail")) {
        self.context = context
    }
    func currentContext() async -> DictationContext { context }
}
```

- [ ] **Step 3: Write the failing test**

`Tests/CiceroKitTests/DictationEngineTests.swift`:

```swift
import Testing
@testable import CiceroKit

@MainActor
@Suite("DictationEngine happy path")
struct DictationEngineHappyPathTests {

    private func makeEngine(
        recorder: FakeRecorder = FakeRecorder(),
        transcriber: FakeTranscriber = FakeTranscriber(),
        polisher: FakePolisher = FakePolisher(),
        inserter: FakeInserter = FakeInserter(),
        contextProvider: FakeContextProvider = FakeContextProvider()
    ) -> DictationEngine {
        DictationEngine(recorder: recorder, transcriber: transcriber,
                        polisher: polisher, inserter: inserter,
                        contextProvider: contextProvider)
    }

    @Test("starts idle")
    func startsIdle() {
        #expect(makeEngine().state == .idle)
    }

    @Test("moves to recording when dictation starts")
    func movesToRecording() async {
        let recorder = FakeRecorder()
        let engine = makeEngine(recorder: recorder)
        await engine.startDictation()
        #expect(engine.state == .recording)
        #expect(recorder.started.value)
    }

    @Test("returns to idle after a full dictation")
    func returnsToIdle() async {
        let engine = makeEngine()
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.state == .idle)
    }

    @Test("inserts the polished text, not the raw transcript")
    func insertsPolishedText() async {
        let inserter = FakeInserter()
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "raw words"),
            polisher: FakePolisher(result: "Polished words."),
            inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value == ["Polished words."])
    }

    @Test("passes the frontmost app context to the polisher")
    func passesContext() async {
        let polisher = FakePolisher()
        let engine = makeEngine(
            polisher: polisher,
            contextProvider: FakeContextProvider(
                context: DictationContext(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(polisher.receivedContext.value.appName == "Slack")
    }

    @Test("remembers the last transcript")
    func remembersLastTranscript() async {
        let engine = makeEngine(polisher: FakePolisher(result: "Polished words."))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.lastTranscript == "Polished words.")
    }

    @Test("ignores a second start while already recording")
    func ignoresDoubleStart() async {
        let engine = makeEngine()
        await engine.startDictation()
        await engine.startDictation()
        #expect(engine.state == .recording)
    }

    @Test("ignores finish when not recording")
    func ignoresStrayFinish() async {
        let inserter = FakeInserter()
        let engine = makeEngine(inserter: inserter)
        await engine.finishDictation()
        #expect(engine.state == .idle)
        #expect(inserter.inserted.value.isEmpty)
    }
}
```

- [ ] **Step 4: Run the test and verify it fails**

Run: `./Scripts/test.sh DictationEngine`
Expected: FAIL — `cannot find 'DictationEngine' in scope`.

- [ ] **Step 5: Write the engine**

`Sources/CiceroKit/DictationEngine.swift`:

```swift
import Foundation
import Observation

/// Orchestrates one dictation: record, transcribe, polish, insert.
///
/// Lives on the main actor so the UI can observe `state` directly. The heavy
/// work happens inside the injected dependencies, which are `Sendable` and
/// manage their own concurrency.
@MainActor
@Observable
public final class DictationEngine {
    public private(set) var state: DictationState = .idle
    public private(set) var lastTranscript: String?

    private let recorder: any AudioRecorder
    private let transcriber: any Transcriber
    private let polisher: any TextPolisher
    private let inserter: any TextInserter
    private let contextProvider: any ContextProvider

    private var context: DictationContext = .unknown

    public init(recorder: any AudioRecorder,
                transcriber: any Transcriber,
                polisher: any TextPolisher,
                inserter: any TextInserter,
                contextProvider: any ContextProvider) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.polisher = polisher
        self.inserter = inserter
        self.contextProvider = contextProvider
    }

    public func startDictation() async {
        guard isStartable else { return }
        context = await contextProvider.currentContext()
        do {
            try await recorder.start()
            state = .recording
        } catch {
            fail(with: error)
        }
    }

    /// Happy path only. Task 3 adds the guards and fallbacks.
    public func finishDictation() async {
        guard state == .recording else { return }
        state = .transcribing
        do {
            let audio = try await recorder.stop()
            let raw = try await transcriber.transcribe(audio)
            state = .polishing
            let text = try await polisher.polish(raw, context: context)
            lastTranscript = text
            state = .inserting
            try await inserter.insert(text)
            state = .idle
        } catch {
            fail(with: error)
        }
    }

    public func cancelDictation() async {
        guard state == .recording else { return }
        await recorder.cancel()
        state = .idle
    }

    private var isStartable: Bool {
        switch state {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func fail(with error: Error) {
        let message = (error as? CiceroError)?.userMessage ?? error.localizedDescription
        state = .failed(message)
    }
}
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `./Scripts/test.sh DictationEngine`
Expected: PASS, 8 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CiceroKit Tests/CiceroKitTests
git commit -m "Add dictation engine with happy-path state machine"
```

---

### Task 3: Engine error handling and the golden rule

Every failure path from the spec, proven by test. The most important behavior in the app: a broken polisher or a broken paste must never cost the user their words.

**Files:**
- Modify: `Sources/CiceroKit/DictationEngine.swift`
- Test: `Tests/CiceroKitTests/DictationEngineErrorTests.swift`

**Interfaces:**
- Consumes: everything from Task 2.
- Produces: no signature changes. Adds three behaviors to `DictationEngine`: silent audio and blank transcripts insert nothing, and a failing polisher falls back to the raw transcript.

- [ ] **Step 1: Write the failing test**

`Tests/CiceroKitTests/DictationEngineErrorTests.swift`:

```swift
import Testing
@testable import CiceroKit

@MainActor
@Suite("DictationEngine error handling")
struct DictationEngineErrorTests {

    private func makeEngine(
        recorder: FakeRecorder = FakeRecorder(),
        transcriber: FakeTranscriber = FakeTranscriber(),
        polisher: FakePolisher = FakePolisher(),
        inserter: FakeInserter = FakeInserter()
    ) -> DictationEngine {
        DictationEngine(recorder: recorder, transcriber: transcriber,
                        polisher: polisher, inserter: inserter,
                        contextProvider: FakeContextProvider())
    }

    @Test("falls back to the raw transcript when polishing fails")
    func polisherFailureInsertsRawText() async {
        let inserter = FakeInserter()
        let engine = makeEngine(
            transcriber: FakeTranscriber(result: "raw words"),
            polisher: FakePolisher(error: .polishingFailed("modelo indisponível")),
            inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value == ["raw words"])
        #expect(engine.state == .idle)
    }

    @Test("silent audio inserts nothing and returns to idle")
    func silentAudioInsertsNothing() async {
        let inserter = FakeInserter()
        let engine = makeEngine(
            recorder: FakeRecorder(buffer: AudioBuffer(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)),
            inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value.isEmpty)
        #expect(engine.state == .idle)
    }

    @Test("a blank transcript inserts nothing")
    func blankTranscriptInsertsNothing() async {
        let inserter = FakeInserter()
        let engine = makeEngine(transcriber: FakeTranscriber(result: "   \n "), inserter: inserter)
        await engine.startDictation()
        await engine.finishDictation()
        #expect(inserter.inserted.value.isEmpty)
        #expect(engine.state == .idle)
    }

    @Test("transcription failure surfaces a message and returns to a startable state")
    func transcriptionFailure() async {
        let engine = makeEngine(transcriber: FakeTranscriber(error: .transcriptionFailed("modelo ausente")))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.state == .failed(CiceroError.transcriptionFailed("modelo ausente").userMessage))
        await engine.startDictation()
        #expect(engine.state == .recording)
    }

    @Test("recording failure surfaces a message")
    func recordingFailure() async {
        let engine = makeEngine(recorder: FakeRecorder(startError: .recordingFailed("sem microfone")))
        await engine.startDictation()
        #expect(engine.state == .failed(CiceroError.recordingFailed("sem microfone").userMessage))
    }

    @Test("insertion failure keeps the transcript retrievable")
    func insertionFailureKeepsTranscript() async {
        let engine = makeEngine(
            polisher: FakePolisher(result: "Palavras polidas."),
            inserter: FakeInserter(error: .insertionBlockedBySecureInput))
        await engine.startDictation()
        await engine.finishDictation()
        #expect(engine.lastTranscript == "Palavras polidas.")
        #expect(engine.state == .failed(CiceroError.insertionBlockedBySecureInput.userMessage))
    }

    @Test("cancelling during recording inserts nothing")
    func cancelInsertsNothing() async {
        let recorder = FakeRecorder()
        let inserter = FakeInserter()
        let engine = makeEngine(recorder: recorder, inserter: inserter)
        await engine.startDictation()
        await engine.cancelDictation()
        #expect(engine.state == .idle)
        #expect(recorder.cancelled.value)
        #expect(inserter.inserted.value.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `./Scripts/test.sh DictationEngineError`

Expected: FAIL, exactly 3 of the 7 tests:
- `polisherFailureInsertsRawText` — Task 2 lets the polisher's error propagate, so nothing is inserted
- `silentAudioInsertsNothing` — Task 2 has no silence guard
- `blankTranscriptInsertsNothing` — Task 2 has no blank-transcript guard

The other 4 pass already; they lock in behavior Task 2 got right, so it cannot regress.

- [ ] **Step 3: Add the guards and the polishing fallback**

⚠️ **Do not replace `finishDictation()` wholesale.** Task 2 went through three review rounds hardening this method's concurrency, and its body now carries a generation-ownership check after every suspension point. Overwriting it with a simpler version silently reverts all of that. You are **inserting three things** into the existing structure, leaving every `guard isCurrent(myGeneration)` exactly where it is:

1. a silence guard immediately after the existing `isCurrent` check that follows `recorder.stop()`
2. a blank-transcript guard immediately after the existing `isCurrent` check that follows `transcriber.transcribe(...)`
3. a call to a new `polished(_:)` helper in place of the direct `polisher.polish(...)` call

The result should read exactly like this — note that every generation guard from Task 2 survives:

```swift
    public func finishDictation() async {
        guard state == .recording, !isCancelling else { return }
        let myGeneration = generation
        let task = startTask
        // Never stop a recorder that has not finished starting.
        await task?.value
        guard isCurrent(myGeneration), state == .recording, !isCancelling else { return }
        state = .transcribing
        do {
            let audio = try await recorder.stop()
            guard isCurrent(myGeneration) else { return }
            // A hotkey brushed by accident must insert nothing.
            guard !audio.isSilent() else {
                state = .idle
                return
            }
            let raw = try await transcriber.transcribe(audio)
            guard isCurrent(myGeneration) else { return }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                return
            }
            state = .polishing
            let text = await polished(raw)
            guard isCurrent(myGeneration) else { return }

            // Golden rule: record the transcript BEFORE attempting insertion,
            // so a failed paste still leaves the words reachable from the menu.
            lastTranscript = text

            state = .inserting
            try await inserter.insert(text)
            guard isCurrent(myGeneration) else { return }
            state = .idle
        } catch {
            guard isCurrent(myGeneration) else { return }
            fail(with: error)
        }
    }

    /// Polishing is an enhancement, never a gate. If the on-device model fails
    /// or is unavailable, the raw transcript still reaches the user.
    private func polished(_ raw: String) async -> String {
        do {
            return try await polisher.polish(raw, context: context)
        } catch {
            return raw
        }
    }
```

Leave `startDictation()`, `cancelDictation()`, `isStartable`, `isCurrent(_:)` and `fail(with:)` untouched.

After making the change, run the Task 2 concurrency tests as well as your own — `./Scripts/test.sh DictationEngine` covers both — and confirm none of them regressed. A Task 2 test failing is the signal that you overwrote the concurrency model rather than adding to it.

- [ ] **Step 4: Run the full test suite and verify it passes**

Run: `./Scripts/test.sh`
Expected: PASS, all tests across `AudioBuffer`, `DictationEngine happy path`, and `DictationEngine error handling`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CiceroKit Tests/CiceroKitTests
git commit -m "Cover every dictation failure path and guarantee transcripts survive"
```

---

### Task 4: Microphone recorder

The first real adapter. Captures from the default input device and converts to the 16 kHz mono float format Whisper expects.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CiceroAudio/MicrophoneRecorder.swift`
- Test: `Tests/CiceroAudioTests/MicrophoneRecorderTests.swift`

**Interfaces:**
- Consumes: `AudioRecorder`, `AudioBuffer`, `CiceroError` from Tasks 1–2.
- Produces: `MicrophoneRecorder()` conforming to `AudioRecorder`, producing `AudioBuffer` at `sampleRate: 16_000`.

- [ ] **Step 1: Add the target to `Package.swift`**

Add to `targets:`:

```swift
        .target(name: "CiceroAudio", dependencies: ["CiceroKit"]),
        .executableTarget(
            name: "CiceroAudioTests",
            dependencies: ["CiceroAudio", "CiceroKit"],
            path: "Tests/CiceroAudioTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
```

Also create `Tests/CiceroAudioTests/Runner.swift` — the same entry point Task 1 established, with a distinct struct name:

```swift
import Testing

@main
struct CiceroAudioTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
```

- [ ] **Step 2: Write the failing test**

This test needs a real microphone, so it is tagged and excluded from the default run. Create `Tests/CiceroAudioTests/MicrophoneRecorderTests.swift`:

```swift
import Testing
import CiceroKit
@testable import CiceroAudio

extension Tag {
    @Tag static var requiresMicrophone: Tag
}

@Suite("MicrophoneRecorder")
struct MicrophoneRecorderTests {

    @Test("records at 16 kHz mono", .tags(.requiresMicrophone))
    func recordsAtWhisperFormat() async throws {
        let recorder = MicrophoneRecorder()
        try await recorder.start()
        try await Task.sleep(for: .seconds(1))
        let buffer = try await recorder.stop()

        #expect(buffer.sampleRate == 16_000)
        #expect(buffer.duration > 0.5)
        #expect(buffer.duration < 2.0)
    }

    @Test("stopping without starting throws", .tags(.requiresMicrophone))
    func stopWithoutStartThrows() async {
        let recorder = MicrophoneRecorder()
        await #expect(throws: CiceroError.self) {
            _ = try await recorder.stop()
        }
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `./Scripts/test.sh MicrophoneRecorder`
Expected: FAIL — `cannot find 'MicrophoneRecorder' in scope`.

- [ ] **Step 4: Write the recorder**

`Sources/CiceroAudio/MicrophoneRecorder.swift`:

```swift
import AVFoundation
import CiceroKit
import Foundation

/// Captures the default input device and hands back 16 kHz mono float audio,
/// the format WhisperKit expects.
///
/// An actor because `AVAudioEngine` and the accumulating sample array are
/// mutable state touched from the audio tap's background thread.
public actor MicrophoneRecorder: AudioRecorder {

    private static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var isRunning = false

    public init() {}

    public func start() async throws {
        guard !isRunning else { return }
        samples.removeAll(keepingCapacity: true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw CiceroError.recordingFailed("nenhum dispositivo de entrada disponível")
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CiceroError.recordingFailed("não foi possível converter o formato de áudio")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = Self.convert(buffer, using: converter, to: targetFormat) else { return }
            Task { await self.append(converted) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CiceroError.recordingFailed(error.localizedDescription)
        }
        isRunning = true
    }

    public func stop() async throws -> AudioBuffer {
        guard isRunning else {
            throw CiceroError.recordingFailed("gravação não estava ativa")
        }
        teardown()
        return AudioBuffer(samples: samples, sampleRate: Self.targetSampleRate)
    }

    public func cancel() async {
        guard isRunning else { return }
        teardown()
        samples.removeAll(keepingCapacity: false)
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            using converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `./Scripts/test.sh MicrophoneRecorder`

The first run triggers a macOS microphone permission prompt for your terminal. Grant it, then run again.

Expected: PASS, 2 tests. If `recordsAtWhisperFormat` reports a duration outside the window, the machine's input device is unusually slow to start; re-run once before investigating.

- [ ] **Step 6: Verify the default test run is unaffected**

Run: `./Scripts/test.sh`
Expected: PASS. Microphone tests run here too; that is fine on the dev machine. The tag exists so CI can exclude them later with `--skip-tags requiresMicrophone`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CiceroAudio Tests/CiceroAudioTests
git commit -m "Add microphone recorder producing 16 kHz mono audio"
```

---

### Task 5: Whisper transcriber

Wraps WhisperKit. The integration test generates its own speech fixture with the built-in `say` command, so no binary audio file is committed.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CiceroWhisper/WhisperKitTranscriber.swift`
- Test: `Tests/CiceroWhisperTests/WhisperKitTranscriberTests.swift`

**Interfaces:**
- Consumes: `Transcriber`, `AudioBuffer`, `CiceroError`.
- Produces: `WhisperKitTranscriber(modelName: String = "large-v3-turbo")` conforming to `Transcriber`, plus `func prepare() async throws` which downloads and loads the model, and `var isReady: Bool`.

- [ ] **Step 1: Add the dependency and target to `Package.swift`**

Add to the package:

```swift
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
```

and to `targets:`:

```swift
        .target(name: "CiceroWhisper", dependencies: [
            "CiceroKit",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .executableTarget(
            name: "CiceroWhisperTests",
            dependencies: ["CiceroWhisper", "CiceroKit"],
            path: "Tests/CiceroWhisperTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
```

Also create `Tests/CiceroWhisperTests/Runner.swift`:

```swift
import Testing

@main
struct CiceroWhisperTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
```

- [ ] **Step 2: Resolve the dependency and record the version**

Run: `swift package resolve && swift package show-dependencies --format json | grep -A2 WhisperKit`

Note the resolved version. WhisperKit's transcription API has changed across releases: if the code in Step 4 does not compile, read the resolved source at `.build/checkouts/WhisperKit/Sources/WhisperKit/Core/WhisperKit.swift` and adapt the initializer and `transcribe` call to the resolved version's signatures. Keep the `Transcriber` conformance identical.

- [ ] **Step 3: Write the failing test**

`Tests/CiceroWhisperTests/WhisperKitTranscriberTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
import CiceroKit
@testable import CiceroWhisper

extension Tag {
    @Tag static var requiresModel: Tag
}

/// Renders speech with the built-in `say` command and loads it as 16 kHz mono
/// float samples, so the suite needs no committed audio fixture.
private func spokenAudio(_ text: String, voice: String? = nil) throws -> AudioBuffer {
    let url = URL.temporaryDirectory.appending(path: "cicero-fixture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    var arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000"]
    if let voice { arguments.append(contentsOf: ["-v", voice]) }
    arguments.append(text)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/say")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CiceroError.transcriptionFailed("`say` falhou ao gerar o fixture")
    }

    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: AVAudioFrameCount(file.length)),
          let channel = buffer.floatChannelData?[0] else {
        throw CiceroError.transcriptionFailed("não foi possível ler o fixture")
    }
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    return AudioBuffer(samples: samples, sampleRate: file.processingFormat.sampleRate)
}

@Suite("WhisperKitTranscriber")
struct WhisperKitTranscriberTests {

    @Test("transcribes spoken English", .tags(.requiresModel), .timeLimit(.minutes(10)))
    func transcribesEnglish() async throws {
        let transcriber = WhisperKitTranscriber()
        try await transcriber.prepare()
        let text = try await transcriber.transcribe(try spokenAudio("The quick brown fox jumps over the lazy dog."))
        #expect(text.lowercased().contains("brown fox"))
    }

    @Test("transcribes spoken Portuguese", .tags(.requiresModel), .timeLimit(.minutes(10)))
    func transcribesPortuguese() async throws {
        let transcriber = WhisperKitTranscriber()
        try await transcriber.prepare()
        let text = try await transcriber.transcribe(try spokenAudio("O rato roeu a roupa do rei.", voice: "Luciana"))
        #expect(text.lowercased().contains("rato"))
    }

    @Test("transcribing before prepare throws", .tags(.requiresModel))
    func transcribeBeforePrepareThrows() async {
        let transcriber = WhisperKitTranscriber()
        await #expect(throws: CiceroError.self) {
            _ = try await transcriber.transcribe(AudioBuffer(samples: Array(repeating: 0.2, count: 16_000), sampleRate: 16_000))
        }
    }
}
```

- [ ] **Step 4: Run the test and verify it fails**

Run: `./Scripts/test.sh WhisperKitTranscriber`
Expected: FAIL — `cannot find 'WhisperKitTranscriber' in scope`.

- [ ] **Step 5: Write the transcriber**

`Sources/CiceroWhisper/WhisperKitTranscriber.swift`:

```swift
import CiceroKit
import Foundation
import WhisperKit

/// Transcribes audio with WhisperKit, which runs Whisper through CoreML on the
/// Neural Engine.
///
/// The model is roughly 1.5 GB and downloads on first use, so loading is an
/// explicit `prepare()` step rather than something hidden inside `transcribe`.
public actor WhisperKitTranscriber: Transcriber {

    private let modelName: String
    private var whisperKit: WhisperKit?

    public init(modelName: String = "large-v3-turbo") {
        self.modelName = modelName
    }

    public var isReady: Bool { whisperKit != nil }

    public func prepare() async throws {
        guard whisperKit == nil else { return }
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: modelName))
        } catch {
            throw CiceroError.transcriptionFailed("não foi possível carregar o modelo: \(error.localizedDescription)")
        }
    }

    public func transcribe(_ audio: AudioBuffer) async throws -> String {
        guard let whisperKit else {
            throw CiceroError.transcriptionFailed("modelo ainda não carregado")
        }
        do {
            // Language is left to auto-detection: the user mixes Portuguese and English.
            let results = try await whisperKit.transcribe(audioArray: audio.samples)
            let text = results.map(\.text).joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw CiceroError.transcriptionFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `./Scripts/test.sh WhisperKitTranscriber`

The first run downloads roughly 1.5 GB. Expect several minutes.

Expected: PASS, 3 tests. If `transcribesPortuguese` fails because the `Luciana` voice is missing, run `say -v '?' | grep pt_BR` to find an installed Portuguese voice and substitute its name in the test.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Package.resolved Sources/CiceroWhisper Tests/CiceroWhisperTests
git commit -m "Add WhisperKit transcriber with self-generating speech fixtures"
```

---

### Task 6: Text polisher

Two implementations behind one protocol: the Apple on-device model, and a passthrough used whenever that model is unavailable. Plus the pure chunker that keeps long dictations inside the model's context window.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CiceroPolish/TextChunker.swift`
- Create: `Sources/CiceroPolish/PassthroughPolisher.swift`
- Create: `Sources/CiceroPolish/FoundationModelsPolisher.swift`
- Test: `Tests/CiceroPolishTests/TextChunkerTests.swift`
- Test: `Tests/CiceroPolishTests/FoundationModelsPolisherTests.swift`

**Interfaces:**
- Consumes: `TextPolisher`, `DictationContext`, `CiceroError`.
- Produces: `TextChunker.chunk(_ text: String, maxCharacters: Int) -> [String]`; `PassthroughPolisher()`; `FoundationModelsPolisher()` with `static var isAvailable: Bool`.

- [ ] **Step 1: Add the target to `Package.swift`**

```swift
        .target(name: "CiceroPolish", dependencies: ["CiceroKit"]),
        .executableTarget(
            name: "CiceroPolishTests",
            dependencies: ["CiceroPolish", "CiceroKit"],
            path: "Tests/CiceroPolishTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
```

Also create `Tests/CiceroPolishTests/Runner.swift`:

```swift
import Testing

@main
struct CiceroPolishTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
```

- [ ] **Step 2: Write the failing chunker test**

`Tests/CiceroPolishTests/TextChunkerTests.swift`:

```swift
import Testing
@testable import CiceroPolish

@Suite("TextChunker")
struct TextChunkerTests {

    @Test("short text stays as one chunk")
    func shortTextIsOneChunk() {
        #expect(TextChunker.chunk("Uma frase curta.", maxCharacters: 100) == ["Uma frase curta."])
    }

    @Test("empty text produces no chunks")
    func emptyProducesNothing() {
        #expect(TextChunker.chunk("   ", maxCharacters: 100).isEmpty)
    }

    @Test("splits on sentence boundaries, never mid-sentence")
    func splitsOnSentenceBoundaries() {
        let text = "Primeira frase aqui. Segunda frase aqui. Terceira frase aqui."
        let chunks = TextChunker.chunk(text, maxCharacters: 40)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.hasSuffix("."))
        }
    }

    @Test("every chunk stays within the limit when sentences allow it")
    func respectsLimit() {
        let text = String(repeating: "Uma frase de teste. ", count: 30)
        for chunk in TextChunker.chunk(text, maxCharacters: 100) {
            #expect(chunk.count <= 100)
        }
    }

    @Test("no content is lost")
    func losesNoWords() {
        let text = "Alfa bravo. Charlie delta. Echo foxtrot."
        let rejoined = TextChunker.chunk(text, maxCharacters: 20).joined(separator: " ")
        #expect(rejoined == text)
    }

    @Test("a single sentence longer than the limit is kept whole")
    func oversizedSentenceSurvives() {
        let sentence = String(repeating: "palavra ", count: 50) + "fim."
        let chunks = TextChunker.chunk(sentence, maxCharacters: 50)
        #expect(chunks.count == 1)
        #expect(chunks[0] == sentence.trimmingCharacters(in: .whitespaces))
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `./Scripts/test.sh TextChunker`
Expected: FAIL — `cannot find 'TextChunker' in scope`.

- [ ] **Step 4: Write the chunker**

`Sources/CiceroPolish/TextChunker.swift`:

```swift
import Foundation

/// Splits a transcript into pieces that fit the on-device model's context
/// window, cutting only at sentence boundaries so the model never sees half a
/// thought.
public enum TextChunker {

    public static func chunk(_ text: String, maxCharacters: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxCharacters else { return [trimmed] }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: trimmed) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= maxCharacters {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A sentence keeps its terminating punctuation. A trailing fragment with
    /// no terminator is still returned, so nothing is dropped.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
```

- [ ] **Step 5: Run the chunker test and verify it passes**

Run: `./Scripts/test.sh TextChunker`
Expected: PASS, 6 tests.

- [ ] **Step 6: Write the passthrough polisher**

`Sources/CiceroPolish/PassthroughPolisher.swift`:

```swift
import CiceroKit

/// Returns the transcript untouched. Used whenever the on-device model is
/// unavailable, so dictation keeps working with raw text.
public struct PassthroughPolisher: TextPolisher {
    public init() {}

    public func polish(_ text: String, context: DictationContext) async throws -> String {
        text
    }
}
```

- [ ] **Step 7: Write the failing polisher test**

`Tests/CiceroPolishTests/FoundationModelsPolisherTests.swift`:

```swift
import Testing
import CiceroKit
@testable import CiceroPolish

extension Tag {
    @Tag static var requiresAppleIntelligence: Tag
}

@Suite("Polishers")
struct PolisherTests {

    @Test("passthrough returns the text unchanged")
    func passthroughIsIdentity() async throws {
        let polished = try await PassthroughPolisher().polish("texto cru", context: .unknown)
        #expect(polished == "texto cru")
    }

    @Test("reports availability without crashing")
    func availabilityIsQueryable() {
        _ = FoundationModelsPolisher.isAvailable
    }

    @Test("removes filler words and adds punctuation", .tags(.requiresAppleIntelligence), .timeLimit(.minutes(2)))
    func polishesRealText() async throws {
        try #require(FoundationModelsPolisher.isAvailable)
        let polisher = FoundationModelsPolisher()
        let raw = "então tipo assim eu queria pedir né uma reunião pra gente falar do projeto amanhã"
        let polished = try await polisher.polish(
            raw,
            context: DictationContext(appName: "Mail", bundleIdentifier: "com.apple.mail"))

        #expect(!polished.isEmpty)
        #expect(polished.lowercased().contains("reunião"))
        #expect(polished.contains(".") || polished.contains(","))
    }

    @Test("preserves meaning rather than answering the text", .tags(.requiresAppleIntelligence), .timeLimit(.minutes(2)))
    func doesNotAnswerTheContent() async throws {
        try #require(FoundationModelsPolisher.isAvailable)
        let polished = try await FoundationModelsPolisher().polish(
            "qual é a capital da França",
            context: .unknown)
        #expect(!polished.lowercased().contains("paris"))
    }
}
```

- [ ] **Step 8: Run the test and verify it fails**

Run: `./Scripts/test.sh Polishers`
Expected: FAIL — `cannot find 'FoundationModelsPolisher' in scope`.

- [ ] **Step 9: Write the FoundationModels polisher**

`Sources/CiceroPolish/FoundationModelsPolisher.swift`:

```swift
import CiceroKit
import FoundationModels
import Foundation

/// Cleans up a transcript using Apple's on-device language model.
///
/// The model ships with macOS 26 and needs no download, but it can be
/// unavailable (Apple Intelligence switched off, assets still downloading).
/// Callers must check `isAvailable` and fall back to `PassthroughPolisher`.
public struct FoundationModelsPolisher: TextPolisher {

    /// Chosen to stay well inside the model's context window while leaving
    /// room for the instructions.
    private let maxCharactersPerChunk: Int

    public init(maxCharactersPerChunk: Int = 1_500) {
        self.maxCharactersPerChunk = maxCharactersPerChunk
    }

    public static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    public func polish(_ text: String, context: DictationContext) async throws -> String {
        guard Self.isAvailable else {
            throw CiceroError.polishingFailed("Apple Intelligence indisponível")
        }
        let chunks = TextChunker.chunk(text, maxCharacters: maxCharactersPerChunk)
        guard !chunks.isEmpty else { return text }

        var polished: [String] = []
        for chunk in chunks {
            polished.append(try await polishChunk(chunk, context: context))
        }
        return polished.joined(separator: " ")
    }

    private func polishChunk(_ chunk: String, context: DictationContext) async throws -> String {
        let session = LanguageModelSession(instructions: instructions(for: context))
        do {
            let response = try await session.respond(to: chunk)
            let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty or absurd response is worse than the raw text.
            return result.isEmpty ? chunk : result
        } catch {
            throw CiceroError.polishingFailed(error.localizedDescription)
        }
    }

    private func instructions(for context: DictationContext) -> String {
        var text = """
        Você limpa transcrições de ditado. Receberá um texto falado transcrito e \
        devolverá a versão escrita dele.

        Regras:
        - Remova vícios de linguagem e hesitações ("tipo", "né", "então assim", "hum").
        - Corrija a pontuação e a capitalização.
        - Preserve o sentido, o vocabulário e o idioma do original. O texto pode \
        misturar português e inglês; mantenha essa mistura.
        - NUNCA responda ao conteúdo. Se o texto for uma pergunta, devolva a pergunta \
        escrita corretamente, não a resposta.
        - NUNCA acrescente informação, comentário ou saudação.
        - Devolva apenas o texto limpo, sem aspas e sem explicação.
        """
        if let appName = context.appName {
            text += "\n- O texto será inserido no app \"\(appName)\". Ajuste apenas o registro ao contexto desse app."
        }
        return text
    }
}
```

- [ ] **Step 10: Run the test and verify it passes**

Run: `./Scripts/test.sh Polishers`
Expected: PASS, 4 tests. If the two tagged tests are skipped, Apple Intelligence is off; enable it in System Settings and re-run, since the app's primary polisher depends on it.

- [ ] **Step 11: Commit**

```bash
git add Package.swift Sources/CiceroPolish Tests/CiceroPolishTests
git commit -m "Add on-device text polisher with chunking and passthrough fallback"
```

---

### Task 7: Clipboard text inserter

Inserts text into whatever app is frontmost, and refuses to do so when a password field has secure input enabled.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CiceroInput/ClipboardTextInserter.swift`
- Create: `Sources/CiceroInput/WorkspaceContextProvider.swift`
- Test: `Tests/CiceroInputTests/ClipboardTextInserterTests.swift`

**Interfaces:**
- Consumes: `TextInserter`, `ContextProvider`, `CiceroError`.
- Produces: `ClipboardTextInserter(restoreDelay: Duration = .milliseconds(180))` conforming to `TextInserter`, with `static func snapshot(of: NSPasteboard) -> [ClipboardTextInserter.Item]`, `static func restore(_: [Item], to: NSPasteboard)` and `static var isSecureInputActive: Bool`; `WorkspaceContextProvider()` conforming to `ContextProvider`.

- [ ] **Step 1: Add the target to `Package.swift`**

```swift
        .target(name: "CiceroInput", dependencies: ["CiceroKit"]),
        .executableTarget(
            name: "CiceroInputTests",
            dependencies: ["CiceroInput", "CiceroKit"],
            path: "Tests/CiceroInputTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
```

Also create `Tests/CiceroInputTests/Runner.swift`:

```swift
import Testing

@main
struct CiceroInputTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
```

- [ ] **Step 2: Write the failing test**

Clipboard save and restore is the risky part and it is testable against a private named pasteboard, never the user's general one. Create `Tests/CiceroInputTests/ClipboardTextInserterTests.swift`:

```swift
import AppKit
import Testing
import CiceroKit
@testable import CiceroInput

@Suite("ClipboardTextInserter clipboard handling")
struct ClipboardTextInserterTests {

    private func makeScratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("br.com.cicero.tests.\(UUID().uuidString)"))
    }

    @Test("restores previously held text")
    func restoresText() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo original", forType: .string)

        let snapshot = ClipboardTextInserter.snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("texto ditado", forType: .string)
        #expect(pasteboard.string(forType: .string) == "texto ditado")

        ClipboardTextInserter.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "conteúdo original")
    }

    @Test("restores an empty clipboard as empty")
    func restoresEmptyClipboard() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()

        let snapshot = ClipboardTextInserter.snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("texto ditado", forType: .string)

        ClipboardTextInserter.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("preserves multiple representations of one item")
    func preservesMultipleTypes() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("texto simples", forType: .string)
        item.setString("<b>rico</b>", forType: .html)
        pasteboard.writeObjects([item])

        let snapshot = ClipboardTextInserter.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("texto ditado", forType: .string)

        ClipboardTextInserter.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "texto simples")
        #expect(pasteboard.string(forType: .html) == "<b>rico</b>")
    }

    @Test("changeCount moves on writes but not on reads")
    func changeCountTracksWritesOnly() {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("um", forType: .string)
        let afterWrite = pasteboard.changeCount

        _ = pasteboard.string(forType: .string)
        #expect(pasteboard.changeCount == afterWrite, "ler não deve mover o changeCount")

        pasteboard.clearContents()
        pasteboard.setString("dois", forType: .string)
        #expect(pasteboard.changeCount > afterWrite, "escrever deve mover o changeCount")
    }

    @Test("refuses to insert while secure input is active")
    func refusesDuringSecureInput() async throws {
        try #require(!ClipboardTextInserter.isSecureInputActive,
                     "Um campo de senha está em foco; feche-o e rode de novo.")
        // With secure input off, the guard must not trigger.
        #expect(!ClipboardTextInserter.isSecureInputActive)
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `./Scripts/test.sh ClipboardTextInserter`
Expected: FAIL — `cannot find 'ClipboardTextInserter' in scope`.

- [ ] **Step 4: Write the inserter**

`Sources/CiceroInput/ClipboardTextInserter.swift`:

```swift
import AppKit
import Carbon.HIToolbox
import CiceroKit
import Foundation

/// Inserts text into the frontmost app by briefly borrowing the clipboard and
/// posting a synthetic ⌘V.
///
/// Accessibility text insertion would avoid touching the clipboard, but many
/// apps (Electron-based ones especially) do not support it. This works
/// everywhere, at the cost of restoring the clipboard afterwards.
public struct ClipboardTextInserter: TextInserter {

    /// One pasteboard item captured with all of its representations.
    public struct Item: Sendable {
        let contents: [(type: String, data: Data)]
    }

    private let restoreDelay: Duration

    public init(restoreDelay: Duration = .milliseconds(180)) {
        self.restoreDelay = restoreDelay
    }

    /// True when a password field holds focus. macOS blocks synthetic key
    /// events in that state, so pasting would silently do nothing.
    public static var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    public func insert(_ text: String) async throws {
        guard !Self.isSecureInputActive else {
            throw CiceroError.insertionBlockedBySecureInput
        }

        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(of: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Self.restore(snapshot, to: pasteboard)
            throw CiceroError.insertionFailed("não foi possível escrever na área de transferência")
        }

        // Remember what the pasteboard looked like right after our own write,
        // so we can tell later whether anyone else touched it.
        let ourChangeCount = pasteboard.changeCount

        do {
            try Self.postPasteShortcut()
        } catch {
            Self.restore(snapshot, to: pasteboard)
            throw error
        }

        // There is no way to observe the target app *reading* the pasteboard —
        // changeCount moves on writes, never on reads — so the wait is a
        // calibrated delay rather than a confirmation.
        try? await Task.sleep(for: restoreDelay)

        // If another process wrote to the clipboard while we waited, its
        // content is newer than ours; restoring would destroy it.
        guard pasteboard.changeCount == ourChangeCount else { return }
        Self.restore(snapshot, to: pasteboard)
    }

    public static func snapshot(of pasteboard: NSPasteboard) -> [Item] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Item(contents: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type.rawValue, data: data)
            })
        }
    }

    public static func restore(_ items: [Item], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for entry in item.contents {
                pasteboardItem.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(restored)
    }

    private static func postPasteShortcut() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw CiceroError.insertionFailed("não foi possível criar a fonte de eventos")
        }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else {
            throw CiceroError.insertionFailed("não foi possível criar o evento de teclado")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
```

`Sources/CiceroInput/WorkspaceContextProvider.swift`:

```swift
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
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `./Scripts/test.sh ClipboardTextInserter`
Expected: PASS, 4 tests.

- [ ] **Step 6: Run the full suite**

Run: `./Scripts/test.sh`
Expected: PASS across all suites.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CiceroInput Tests/CiceroInputTests
git commit -m "Add clipboard text inserter and frontmost-app context provider"
```

---

### Task 8: Global hotkey monitor

Detects hold and release of `⌃⌥Space` anywhere in the system. The matching logic is pure and tested; the event tap wiring is thin.

**Files:**
- Create: `Sources/CiceroInput/HotkeyMatcher.swift`
- Create: `Sources/CiceroInput/HotkeyMonitor.swift`
- Test: `Tests/CiceroInputTests/HotkeyMatcherTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `Hotkey(keyCode:modifiers:)` with `static let defaultHotkey` (`⌃⌥Space`) and `func matches(keyCode:flags:) -> Bool`; `HotkeyMonitor(hotkey:onPress:onRelease:)` with `func start() throws` and `func stop()`.

- [ ] **Step 1: Write the failing test**

`Tests/CiceroInputTests/HotkeyMatcherTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import CiceroInput

@Suite("Hotkey")
struct HotkeyTests {

    private let space: CGKeyCode = 49   // kVK_Space
    private let keyA: CGKeyCode = 0     // kVK_ANSI_A

    @Test("the default hotkey is control + option + space")
    func defaultIsControlOptionSpace() {
        let hotkey = Hotkey.defaultHotkey
        #expect(hotkey.keyCode == space)
        #expect(hotkey.modifiers.contains(.maskControl))
        #expect(hotkey.modifiers.contains(.maskAlternate))
        #expect(!hotkey.modifiers.contains(.maskCommand))
    }

    @Test("matches the exact combination")
    func matchesExactCombination() {
        #expect(Hotkey.defaultHotkey.matches(keyCode: space, flags: [.maskControl, .maskAlternate]))
    }

    @Test("does not match the wrong key")
    func rejectsWrongKey() {
        #expect(!Hotkey.defaultHotkey.matches(keyCode: keyA, flags: [.maskControl, .maskAlternate]))
    }

    @Test("does not match with a modifier missing")
    func rejectsMissingModifier() {
        #expect(!Hotkey.defaultHotkey.matches(keyCode: space, flags: [.maskControl]))
    }

    @Test("does not match with an extra modifier")
    func rejectsExtraModifier() {
        #expect(!Hotkey.defaultHotkey.matches(keyCode: space, flags: [.maskControl, .maskAlternate, .maskCommand]))
    }

    @Test("ignores irrelevant flag bits such as caps lock and numeric pad")
    func ignoresIrrelevantFlags() {
        #expect(Hotkey.defaultHotkey.matches(
            keyCode: space,
            flags: [.maskControl, .maskAlternate, .maskAlphaShift, .maskNumericPad]))
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `./Scripts/test.sh Hotkey`
Expected: FAIL — `cannot find 'Hotkey' in scope`.

- [ ] **Step 3: Write the matcher**

`Sources/CiceroInput/HotkeyMatcher.swift`:

```swift
import CoreGraphics

/// A push-to-talk key combination.
public struct Hotkey: Sendable, Equatable {
    public let keyCode: CGKeyCode
    public let modifiers: CGEventFlags

    public init(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control + Option + Space. Deliberately not `fn`, which collides with
    /// macOS's own emoji and dictation behavior.
    public static let defaultHotkey = Hotkey(
        keyCode: 49, // kVK_Space
        modifiers: [.maskControl, .maskAlternate])

    /// Only these bits are considered; caps lock, numeric pad and coalesced
    /// flags must not defeat a match.
    private static let relevant: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
    ]

    public func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let significant = flags.intersection(Self.relevant)
        return significant == modifiers.intersection(Self.relevant)
    }
}
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `./Scripts/test.sh Hotkey`
Expected: PASS, 6 tests.

- [ ] **Step 5: Write the monitor**

`Sources/CiceroInput/HotkeyMonitor.swift`:

```swift
import AppKit
import CiceroKit
import CoreGraphics
import Foundation

/// Watches for the push-to-talk hotkey system-wide via a CoreGraphics event tap.
///
/// Requires Accessibility permission, which the app needs anyway to post the
/// synthetic ⌘V that inserts text.
@MainActor
public final class HotkeyMonitor {

    private let hotkey: Hotkey
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

    public init(hotkey: Hotkey = .defaultHotkey,
                onPress: @escaping @MainActor () -> Void,
                onRelease: @escaping @MainActor () -> Void) {
        self.hotkey = hotkey
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public func start() throws {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            },
            userInfo: context) else {
            // tapCreate returns nil precisely when Accessibility is not granted.
            throw CiceroError.accessibilityNotGranted
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        runLoopSource = nil
        isHeld = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard hotkey.matches(keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            // Key repeat fires keyDown continuously while held; only the first matters.
            if !isHeld {
                isHeld = true
                onPress()
            }
        case .keyUp:
            if isHeld {
                isHeld = false
                onRelease()
            }
        default:
            return Unmanaged.passUnretained(event)
        }

        // Swallow the event so the hotkey does not reach the focused app.
        return nil
    }
}
```

- [ ] **Step 6: Run the full suite**

Run: `./Scripts/test.sh`
Expected: PASS. `HotkeyMonitor` has no unit test — an event tap cannot be honestly unit tested; it is verified end-to-end in Task 10.

- [ ] **Step 7: Commit**

```bash
git add Sources/CiceroInput Tests/CiceroInputTests
git commit -m "Add global push-to-talk hotkey matcher and event tap monitor"
```

---

### Task 9: Menu bar app and composition root

Wires every adapter into the engine and puts Cicero in the menu bar. After this task the code is complete; it just cannot run yet without the bundle from Task 10.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CiceroApp/Palette.swift`
- Create: `Sources/CiceroApp/Permissions.swift`
- Create: `Sources/CiceroApp/AppDelegate.swift`
- Create: `Sources/CiceroApp/main.swift`

**Interfaces:**
- Consumes: `DictationEngine`, `MicrophoneRecorder`, `WhisperKitTranscriber`, `FoundationModelsPolisher`, `PassthroughPolisher`, `ClipboardTextInserter`, `WorkspaceContextProvider`, `HotkeyMonitor`, `Hotkey`.
- Produces: executable target `CiceroApp`; `Palette` color constants used by Task 11.

- [ ] **Step 1: Add the executable target to `Package.swift`**

```swift
        .executableTarget(name: "CiceroApp", dependencies: [
            "CiceroKit", "CiceroAudio", "CiceroWhisper", "CiceroPolish", "CiceroInput",
        ]),
```

- [ ] **Step 2: Write the palette**

`Sources/CiceroApp/Palette.swift`:

```swift
import AppKit

/// Cicero's brand colors: Roman marble and imperial purple.
public enum Palette {
    public static let marble = NSColor(srgbRed: 0xF4 / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)
    public static let tyrianPurple = NSColor(srgbRed: 0x6B / 255, green: 0x2D / 255, blue: 0x4F / 255, alpha: 1)
    public static let laurel = NSColor(srgbRed: 0x6B / 255, green: 0x7A / 255, blue: 0x4F / 255, alpha: 1)
    public static let bronze = NSColor(srgbRed: 0xC9 / 255, green: 0xA2 / 255, blue: 0x27 / 255, alpha: 1)
    public static let basalt = NSColor(srgbRed: 0x1C / 255, green: 0x1A / 255, blue: 0x19 / 255, alpha: 1)

    public static let tagline = "Verba volant, scripta manent"
}
```

- [ ] **Step 3: Write the permissions helper**

`Sources/CiceroApp/Permissions.swift`:

```swift
import AVFoundation
import AppKit
import ApplicationServices

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
```

- [ ] **Step 4: Write the composition root**

`Sources/CiceroApp/AppDelegate.swift`:

```swift
import AppKit
import CiceroAudio
import CiceroInput
import CiceroKit
import CiceroPolish
import CiceroWhisper
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var engine: DictationEngine?
    private var hotkeyMonitor: HotkeyMonitor?
    private let transcriber = WhisperKitTranscriber()
    private var modelIsReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        buildEngine()
        Task { await requestPermissionsAndStart() }
        Task { await loadModel() }
    }

    // MARK: - Composition

    private func buildEngine() {
        // The polisher is chosen once at launch: Apple's on-device model when
        // available, otherwise raw text still reaches the user.
        // Written as if/else rather than a ternary because the two branches
        // have different concrete types.
        let polisher: any TextPolisher
        if FoundationModelsPolisher.isAvailable {
            polisher = FoundationModelsPolisher()
        } else {
            polisher = PassthroughPolisher()
        }

        let engine = DictationEngine(
            recorder: MicrophoneRecorder(),
            transcriber: transcriber,
            polisher: polisher,
            inserter: ClipboardTextInserter(),
            contextProvider: WorkspaceContextProvider())
        self.engine = engine

        hotkeyMonitor = HotkeyMonitor(
            hotkey: .defaultHotkey,
            onPress: { [weak self] in
                guard let self, self.modelIsReady else { return }
                Task { await self.engine?.startDictation(); self.refreshStatusItem() }
            },
            onRelease: { [weak self] in
                guard let self else { return }
                Task { await self.engine?.finishDictation(); self.refreshStatusItem() }
            })
    }

    private func requestPermissionsAndStart() async {
        if Permissions.microphoneStatus == .notDetermined {
            _ = await Permissions.requestMicrophone()
        }
        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
        do {
            try hotkeyMonitor?.start()
        } catch {
            presentAlert(title: "Permissão de Acessibilidade necessária",
                         message: "O Cicero precisa dela para ouvir o atalho global e colar o texto.",
                         pane: .accessibility)
        }
        refreshStatusItem()
    }

    private func loadModel() async {
        do {
            try await transcriber.prepare()
            modelIsReady = true
        } catch {
            presentAlert(title: "Não foi possível carregar o modelo",
                         message: (error as? CiceroError)?.userMessage ?? error.localizedDescription,
                         pane: nil)
        }
        refreshStatusItem()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "laurel.leading", accessibilityDescription: "Cicero")
        item.button?.image?.isTemplate = true
        statusItem = item
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if let transcript = engine?.lastTranscript, !transcript.isEmpty {
            let item = NSMenuItem(title: "Copiar última transcrição",
                                  action: #selector(copyLastTranscript),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let preview = NSMenuItem(title: String(transcript.prefix(60)), action: nil, keyEquivalent: "")
            preview.isEnabled = false
            menu.addItem(preview)
            menu.addItem(.separator())
        }

        let about = NSMenuItem(title: "Cicero — \(Palette.tagline)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private var statusLine: String {
        guard modelIsReady else { return "Carregando modelo…" }
        switch engine?.state ?? .idle {
        case .idle:         return "Pronto — segure ⌃⌥Espaço"
        case .recording:    return "Ouvindo…"
        case .transcribing: return "Transcrevendo…"
        case .polishing:    return "Polindo…"
        case .inserting:    return "Inserindo…"
        case .failed(let message): return message
        }
    }

    @objc private func copyLastTranscript() {
        guard let transcript = engine?.lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func presentAlert(title: String, message: String, pane: Permissions.SettingsPane?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if pane != nil { alert.addButton(withTitle: "Abrir Ajustes") }
        alert.addButton(withTitle: "Fechar")
        if alert.runModal() == .alertFirstButtonReturn, let pane {
            Permissions.openSettings(pane)
        }
    }
}
```

- [ ] **Step 5: Write the entry point**

`Sources/CiceroApp/main.swift`:

```swift
import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
```

- [ ] **Step 6: Verify it builds and the suite still passes**

Run: `swift build && ./Scripts/test.sh`
Expected: build succeeds, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CiceroApp
git commit -m "Add menu bar app shell wiring every adapter into the engine"
```

---

### Task 10: App bundle, stable signing, and end-to-end verification

Turns the executable into a real `Cicero.app` that can hold permissions across rebuilds. This is where the app first runs for real.

**Files:**
- Create: `Scripts/create-signing-identity.sh`
- Create: `Scripts/bundle.sh`
- Create: `Resources/Info.plist`
- Create: `README.md`

**Interfaces:**
- Consumes: the `CiceroApp` executable from Task 9.
- Produces: `dist/Cicero.app`, signed with the stable identity `Cicero Dev`.

- [ ] **Step 1: Write the `Info.plist`**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Cicero</string>
    <key>CFBundleDisplayName</key>
    <string>Cicero</string>
    <key>CFBundleIdentifier</key>
    <string>br.com.cicero.app</string>
    <key>CFBundleExecutable</key>
    <string>CiceroApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>O Cicero usa o microfone para transcrever o que você fala.</string>
</dict>
</plist>
```

- [ ] **Step 2: Write the signing identity script**

This is the fix for the rebuild problem: an ad-hoc signature changes on every build, so macOS revokes Accessibility permission each time. A stable self-signed identity keeps it.

`Scripts/create-signing-identity.sh`:

```bash
#!/usr/bin/env bash
# Creates a stable self-signed code signing identity named "Cicero Dev".
# Run once. Without it, every rebuild changes the app's signature and macOS
# revokes the Accessibility permission you just granted.
set -euo pipefail

IDENTITY="Cicero Dev"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Identidade \"$IDENTITY\" já existe."
    exit 0
fi

cat <<'EOF'
A criação da identidade é interativa e precisa ser feita no Acesso às Chaves:

  1. Abra o app "Acesso às Chaves"
  2. Menu: Acesso às Chaves > Assistente de Certificado > Criar um certificado…
  3. Nome:            Cicero Dev
     Tipo de identidade: Raiz autoassinada
     Tipo de certificado: Assinatura de código
  4. Marque "Permitir que eu sobreponha os padrões" e avance aceitando tudo
  5. Conclua e rode este script de novo para confirmar

EOF
exit 1
```

- [ ] **Step 3: Write the bundle script**

`Scripts/bundle.sh`:

```bash
#!/usr/bin/env bash
# Builds Cicero and assembles a signed .app bundle at dist/Cicero.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Cicero.app"
IDENTITY="Cicero Dev"

echo "==> Compilando"
swift build -c release --package-path "$ROOT"
BINARY="$(swift build -c release --package-path "$ROOT" --show-bin-path)/CiceroApp"

echo "==> Montando o bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/CiceroApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> Assinando"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "    assinado com \"$IDENTITY\" (permissões sobrevivem a rebuilds)"
else
    codesign --force --deep --sign - "$APP"
    echo "    AVISO: assinado ad-hoc. Rode Scripts/create-signing-identity.sh,"
    echo "    senão você terá que reconceder a permissão de Acessibilidade a cada build."
fi

echo "==> Pronto: $APP"
```

- [ ] **Step 4: Make the scripts executable and build the bundle**

```bash
chmod +x Scripts/bundle.sh Scripts/create-signing-identity.sh
./Scripts/create-signing-identity.sh || true
./Scripts/bundle.sh
```

Expected: `dist/Cicero.app` exists. Follow the instructions printed by `create-signing-identity.sh` before continuing, so permissions persist.

- [ ] **Step 5: Verify the bundle is well-formed**

```bash
codesign --verify --verbose dist/Cicero.app
/usr/libexec/PlistBuddy -c "Print :LSUIElement" dist/Cicero.app/Contents/Info.plist
```

Expected: `valid on disk`, `satisfies its Designated Requirement`, and `true`.

- [ ] **Step 6: End-to-end manual verification**

Run `open dist/Cicero.app`, then work through this checklist. Record the result of each line.

1. A laurel glyph appears in the menu bar, and no icon appears in the Dock.
2. macOS prompts for microphone access. Grant it.
3. macOS prompts for Accessibility. Grant it, then relaunch the app.
4. The menu shows "Carregando modelo…", then "Pronto — segure ⌃⌥Espaço" once the model finishes loading.
5. Open TextEdit. Hold `⌃⌥Space`, say a sentence in Portuguese, release. The polished text appears in TextEdit within a few seconds.
6. Copy some text to the clipboard, dictate again, then press `⌘V` manually. The originally copied text is still there — the clipboard was restored.
7. Dictate a sentence that mixes Portuguese and English. Both languages survive.
8. Hold the hotkey and release it without speaking. Nothing is inserted.
9. Open the menu. "Copiar última transcrição" is present and copies the last dictation.
10. Rebuild with `./Scripts/bundle.sh` and relaunch. Accessibility permission is still granted, with no new prompt.

- [ ] **Step 7: Write the README**

`README.md`:

```markdown
# Cicero

> *Verba volant, scripta manent*

Ditado por voz para macOS, inteiramente local. Segure `⌃⌥Espaço`, fale, solte —
o texto transcrito e polido aparece no app em que você está.

Nenhum áudio sai da máquina. A transcrição roda no Whisper via CoreML e o
polimento usa o modelo on-device da Apple.

## Requisitos

- macOS 26 ou superior, Apple Silicon
- Apple Intelligence ativado (sem ele o Cicero cola o texto cru)
- Swift 6.3 (Command Line Tools bastam; o Xcode não é necessário)

## Como rodar

```bash
./Scripts/create-signing-identity.sh   # uma vez só
./Scripts/bundle.sh
open dist/Cicero.app
```

Na primeira execução o Cicero baixa o modelo Whisper (~1,5 GB) e pede permissão
de microfone e de Acessibilidade.

## Testes

```bash
./Scripts/test.sh
```
```

- [ ] **Step 8: Commit**

```bash
git add Scripts Resources README.md
git commit -m "Add app bundle assembly with stable signing identity"
```

---

### Task 11: Dictation HUD

A floating pill that shows dictation state without words. The last piece of the skeleton.

**Files:**
- Create: `Sources/CiceroApp/HUDWindow.swift`
- Modify: `Sources/CiceroApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `DictationState`, `Palette`.
- Produces: `HUDWindow()` with `func show(state: DictationState)` and `func hide()`.

- [ ] **Step 1: Write the HUD**

`Sources/CiceroApp/HUDWindow.swift`:

```swift
import AppKit
import CiceroKit

/// A small floating pill near the bottom of the screen showing dictation
/// state. Borderless, non-activating, and never steals focus from the app the
/// user is dictating into.
@MainActor
final class HUDWindow {

    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        // NSPanel, not NSWindow: `.nonactivatingPanel` is a panel-only style
        // mask and is inert on a plain NSWindow. Combined with
        // `becomesKeyOnlyIfNeeded`, this keeps the caret in the app the user
        // is dictating into — showing the HUD must never steal focus.
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.hasShadow = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 44))
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.marble.cgColor
        container.layer?.cornerRadius = 22
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Palette.bronze.withAlphaComponent(0.4).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.frame = NSRect(x: 18, y: 16, width: 12, height: 12)
        container.addSubview(dot)

        label.frame = NSRect(x: 40, y: 12, width: 168, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Palette.basalt
        container.addSubview(label)

        window.contentView = container
    }

    func show(state: DictationState) {
        label.stringValue = caption(for: state)
        dot.layer?.backgroundColor = color(for: state).cgColor
        position()
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96))
    }

    private func caption(for state: DictationState) -> String {
        switch state {
        case .idle:         return "Pronto"
        case .recording:    return "Ouvindo…"
        case .transcribing: return "Transcrevendo…"
        case .polishing:    return "Polindo…"
        case .inserting:    return "Inserindo…"
        case .failed:       return "Algo deu errado"
        }
    }

    private func color(for state: DictationState) -> NSColor {
        switch state {
        case .recording:            return Palette.tyrianPurple
        case .transcribing, .polishing, .inserting: return Palette.bronze
        case .idle:                 return Palette.laurel
        case .failed:               return .systemRed
        }
    }
}
```

- [ ] **Step 2: Show the HUD from the app delegate**

In `Sources/CiceroApp/AppDelegate.swift`, add the property beside the others:

```swift
    private let hud = HUDWindow()
```

Then replace the two hotkey closures inside `buildEngine()` with versions that drive the HUD:

```swift
        hotkeyMonitor = HotkeyMonitor(
            hotkey: .defaultHotkey,
            onPress: { [weak self] in
                guard let self, self.modelIsReady else { return }
                Task {
                    await self.engine?.startDictation()
                    self.syncUI()
                }
            },
            onRelease: { [weak self] in
                guard let self else { return }
                Task {
                    await self.engine?.finishDictation()
                    self.syncUI()
                }
            })
```

And add this method to the class:

```swift
    private func syncUI() {
        refreshStatusItem()
        guard let state = engine?.state else { return }
        switch state {
        case .idle:
            hud.hide()
        default:
            hud.show(state: state)
        }
    }
```

- [ ] **Step 3: Drive the HUD through the whole dictation, not just its ends**

`finishDictation()` moves through transcribing, polishing and inserting before returning, so the two calls above only show the first and last state. Replace the `onRelease` closure with one that polls while the engine works:

```swift
            onRelease: { [weak self] in
                guard let self else { return }
                Task {
                    let ticker = Task { [weak self] in
                        while !Task.isCancelled {
                            self?.syncUI()
                            try? await Task.sleep(for: .milliseconds(120))
                        }
                    }
                    await self.engine?.finishDictation()
                    ticker.cancel()
                    self.syncUI()
                }
            })
```

- [ ] **Step 4: Rebuild and verify**

```bash
swift build && ./Scripts/test.sh && ./Scripts/bundle.sh && open dist/Cicero.app
```

Expected: build and tests pass. Then verify by hand:

1. Hold `⌃⌥Space`. The HUD appears near the bottom of the screen with a purple dot reading "Ouvindo…".
2. Release. The dot turns bronze and the caption moves through "Transcrevendo…", "Polindo…" and "Inserindo…".
3. Once the text lands, the HUD disappears.
4. The HUD never steals focus: the caret stays in the target app the whole time.

- [ ] **Step 5: Commit**

```bash
git add Sources/CiceroApp
git commit -m "Add floating dictation HUD driven by engine state"
```

---

## Done

The skeleton is complete when Task 11's manual checks pass: holding `⌃⌥Space`, speaking, and releasing inserts polished text into any app, entirely on-device.

**Deliberately not built** (each is its own future plan): hands-free double-tap mode, custom vocabulary, transcript history beyond the last one, a preferences window, the drawn laurel app icon and refined HUD visuals, and distribution with notarization.
