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
