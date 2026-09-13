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
