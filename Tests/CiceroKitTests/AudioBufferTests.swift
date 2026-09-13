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

    // MARK: - The 0.01 boundary itself
    //
    // This threshold decides whether a dictation is thrown away, and it has
    // very little room: MicrophoneRecorderTests measures this machine's real
    // quiet-room captures at RMS 0.0083–0.0095, so the line sits only 5–20%
    // above the actual noise floor. The tests above (0.001 and 0.4) are two
    // orders of magnitude away from it and would pass under almost any
    // constant and either comparison operator, which left both unverified.

    @Test("just below the threshold is silent")
    func justBelowThresholdIsSilent() {
        let buffer = AudioBuffer(samples: Array(repeating: 0.0099, count: 16_000), sampleRate: 16_000)
        #expect(buffer.isSilent())
    }

    @Test("just above the threshold is not silent")
    func justAboveThresholdIsNotSilent() {
        let buffer = AudioBuffer(samples: Array(repeating: 0.0101, count: 16_000), sampleRate: 16_000)
        #expect(!buffer.isSilent())
    }

    @Test("the comparison is strict: RMS exactly at the threshold is not silence")
    func exactlyAtThresholdIsNotSilent() {
        // 0.5 rather than the 0.01 default because 0.5 is exact in binary
        // floating point — the RMS of a constant buffer lands on it precisely,
        // so this pins `<` versus `<=` without depending on rounding.
        let buffer = AudioBuffer(samples: Array(repeating: 0.5, count: 16_000), sampleRate: 16_000)
        #expect(!buffer.isSilent(threshold: 0.5))
        #expect(buffer.isSilent(threshold: 0.50001))
    }
}
