import CiceroKit
import Foundation
@preconcurrency import WhisperKit

/// Transcreve áudio com WhisperKit, que roda Whisper via CoreML no Neural Engine.
///
/// O modelo tem cerca de 1.5 GB e é baixado no primeiro uso, então o
/// carregamento é um passo explícito de `prepare()` em vez de algo escondido
/// dentro de `transcribe`.
public actor WhisperKitTranscriber: Transcriber {

    private let modelName: String
    private var whisperKit: WhisperKit?

    /// `modelName` is matched as a glob against folder names in the
    /// `argmaxinc/whisperkit-coreml` repo. The resolved WhisperKit 0.18.0
    /// repo names this model `openai_whisper-large-v3_turbo` (underscore
    /// before `turbo`, not a hyphen), so the default here uses `large-v3_turbo`
    /// to match it — the hyphenated `large-v3-turbo` spelling of the model's
    /// common name does not match any folder and fails to resolve.
    public init(modelName: String = "large-v3_turbo") {
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
            // O idioma é deixado para detecção automática: o usuário mistura
            // português e inglês.
            let results = try await whisperKit.transcribe(audioArray: audio.samples)
            let text = results.map(\.text).joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw CiceroError.transcriptionFailed(error.localizedDescription)
        }
    }
}
