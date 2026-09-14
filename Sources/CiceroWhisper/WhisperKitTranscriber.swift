import CiceroKit
import Foundation
// WhisperKit's public API predates strict-concurrency auditing at the resolved
// 0.18.0 release (its types aren't marked Sendable), but every use here is
// confined to this actor's isolation domain, so treating it as @preconcurrency
// is safe rather than a suppressed real hazard.
@preconcurrency import WhisperKit

/// Transcreve áudio com WhisperKit, que roda Whisper via CoreML no Neural Engine.
///
/// O modelo tem cerca de 1.5 GB e é baixado no primeiro uso, então o
/// carregamento é um passo explícito de `prepare()` em vez de algo escondido
/// dentro de `transcribe`.
public actor WhisperKitTranscriber: Transcriber {

    private let modelName: String
    private let language: String?
    private var whisperKit: WhisperKit?

    /// The in-flight model load, if any, plus a generation counter so a
    /// failed attempt only clears its own entry (see `prepare()`).
    private var loadTask: Task<WhisperKit, Error>?
    private var loadGeneration = 0

    /// `modelName` is matched as a glob against folder names in the
    /// `argmaxinc/whisperkit-coreml` repo. The resolved WhisperKit 0.18.0
    /// repo names this model `openai_whisper-large-v3_turbo` (underscore
    /// before `turbo`, not a hyphen), so the default here uses `large-v3_turbo`
    /// to match it — the hyphenated `large-v3-turbo` spelling of the model's
    /// common name does not match any folder and fails to resolve.
    /// `language` is the BCP-47-ish code Whisper conditions its decoder on
    /// (`"pt"`, `"en"`, …). `nil` leaves it to WhisperKit's auto-detection.
    ///
    /// Auto-detection is unreliable on the two-to-four-second clips this app
    /// produces: detection reads a single window, and on a short clip it
    /// regularly picks the wrong language. Whisper then conditions its decoder
    /// on that token and *generates text in that language* — so Portuguese
    /// speech comes back as an English paraphrase, or as Portuguese with words
    /// the speaker never said. Pinning the language is what makes short
    /// dictations reliable.
    public init(modelName: String = "large-v3_turbo", language: String? = nil) {
        self.modelName = modelName
        self.language = language
    }

    public var isReady: Bool { whisperKit != nil }

    /// Loads the model, single-flight.
    ///
    /// Actors are reentrant across suspension points: without this, two
    /// `prepare()` calls that both arrive before the first `await` completes
    /// would each see `whisperKit == nil` and start their own concurrent
    /// `WhisperKit(...)` construction, racing to download and rename the same
    /// file in the shared Hugging Face cache. Instead, the first caller
    /// starts the load and stores it; any caller that arrives while it is in
    /// flight awaits that same `Task` rather than starting a second one.
    ///
    /// `loadGeneration` exists so a failed load only clears the slot it
    /// itself created: if caller A's attempt fails and is retried by caller B
    /// (bumping the generation) before caller A's `catch` runs, A must not
    /// wipe out B's fresh, still in-flight attempt.
    public func prepare() async throws {
        if whisperKit != nil { return }

        let task: Task<WhisperKit, Error>
        let generation: Int
        if let inFlight = loadTask {
            task = inFlight
            generation = loadGeneration
        } else {
            loadGeneration += 1
            generation = loadGeneration
            let modelName = modelName
            // `prewarm` forces CoreML's ahead-of-time compilation for the
            // Neural Engine to happen here rather than inside the user's first
            // dictation. Without it the first transcription spends around two
            // minutes in ANECompiler while the menu says "Transcrevendo…" and
            // nothing appears to be happening; every later one takes about a
            // second. `prepare()` is already off the dictation path and already
            // shows "Carregando modelo…", so this is where that cost belongs.
            let newTask = Task {
                try await WhisperKit(WhisperKitConfig(model: modelName, prewarm: true))
            }
            loadTask = newTask
            task = newTask
        }

        let began = Date()
        do {
            let loaded = try await task.value
            ciceroLog.notice("prepare: modelo pronto em \(Date().timeIntervalSince(began), format: .fixed(precision: 1))s")
            whisperKit = loaded
            loadTask = nil
        } catch {
            if loadGeneration == generation {
                loadTask = nil
            }
            throw CiceroError.transcriptionFailed("não foi possível carregar o modelo: \(error.localizedDescription)")
        }
    }

    public func transcribe(_ audio: CiceroKit.AudioBuffer) async throws -> String {
        guard let whisperKit else {
            throw CiceroError.transcriptionFailed("modelo ainda não carregado")
        }
        do {
            // Passing explicit options matters: WhisperKit's default leaves
            // `language` nil, and auto-detection on a short clip regularly
            // picks the wrong one. See the note on `init(modelName:language:)`.
            let options = DecodingOptions(task: .transcribe, language: language)
            let results = try await whisperKit.transcribe(audioArray: audio.samples,
                                                          decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
            return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            throw CiceroError.transcriptionFailed(error.localizedDescription)
        }
    }
}
