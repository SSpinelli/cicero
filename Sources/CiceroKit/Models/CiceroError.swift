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
