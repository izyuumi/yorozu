import Foundation
import Testing
@testable import VoiceText

struct AudioWindowPlanTests {
    private let rate = 16_000

    /// A clip of `seconds`, a 440 Hz tone everywhere except the silent `gaps` (start and length in seconds).
    private func clip(seconds: Double, gaps: [(Double, Double)] = []) -> [Float] {
        var samples = (0..<Int(seconds * Double(rate))).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        for (start, length) in gaps {
            let from = Int(start * Double(rate)), to = min(samples.count, Int((start + length) * Double(rate)))
            for index in from..<to { samples[index] = 0 }
        }
        return samples
    }

    private func plan(_ samples: [Float]) -> [AudioWindow] {
        AudioWindowPlan.windows(sampleCount: samples.count, sampleRate: rate, activity: VoiceActivity(samples: samples, sampleRate: rate))
    }

    private func fits(_ window: AudioWindow) -> Bool {
        AudioWindowPlan.tokens(samples: window.range.count, sampleRate: rate) <= AudioWindowPlan.contextTokens
    }

    @Test func theLongestWindowIsAboutThreeMinutes() {
        let longest = AudioWindowPlan.longestWindow(sampleRate: rate)
        #expect(abs(Double(longest) / Double(rate) - 178.6) < 0.5)
        #expect(AudioWindowPlan.tokens(samples: longest, sampleRate: rate) <= 8_192)
        #expect(AudioWindowPlan.tokens(samples: longest + 1, sampleRate: rate) > 8_192)
    }

    private var preferred: Int { Int(AudioWindowPlan.preferredWindowSeconds) * rate }

    @Test func aShortClipIsOneWindow() {
        let samples = clip(seconds: 30)
        let windows = plan(samples)
        #expect(windows.map(\.range) == [0..<samples.count])
        #expect(windows.first?.voiced == true)
        #expect(abs((windows.first?.speechSeconds ?? 0) - 30) < 0.001)
    }

    @Test func anEmptyClipIsOneEmptyWindow() {
        #expect(plan([]) == [AudioWindow(range: 0..<0, speechSeconds: 0)])
    }

    @Test func aClipAtThePreferredLengthIsOneWindow() {
        let activity = VoiceActivity(energies: [], frameLength: 1_600)
        #expect(AudioWindowPlan.windows(sampleCount: preferred, sampleRate: rate, activity: activity).count == 1)
        let over = AudioWindowPlan.windows(sampleCount: preferred + 1, sampleRate: rate, activity: activity)
        #expect(over.count == 2)
        #expect(over.allSatisfy { $0.range.count <= preferred })
        #expect(over.last?.range.upperBound == preferred + 1)
    }

    @Test func withoutThePreferredCapAClipExactlyAtTheContextLimitIsOneWindow() {
        let longest = AudioWindowPlan.longestWindow(sampleRate: rate)
        let activity = VoiceActivity(energies: [], frameLength: 1_600)
        func windows(_ count: Int) -> [AudioWindow] {
            AudioWindowPlan.windows(sampleCount: count, sampleRate: rate, activity: activity, preferredWindowSeconds: 1_000)
        }
        #expect(windows(longest).count == 1)
        let over = windows(longest + 1)
        #expect(over.count == 2)
        #expect(over.allSatisfy { $0.range.count <= longest })
        #expect(over.last?.range.upperBound == longest + 1)
    }

    @Test func aTwoAndAHalfMinuteClipIsTwoWindows() {
        let windows = plan(clip(seconds: 150))
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.range.count <= preferred && $0.voiced })
    }

    @Test func aTenMinuteClipIsCutIntoWindowsOfAtMostNinetySeconds() {
        // Pauses of 0.6 s every 15 s, plus a longer one at 75 s, within the first window's last 20 s.
        let gaps = stride(from: 7.0, to: 600, by: 15).map { ($0, 0.6) } + [(75.0, 0.8)]
        let samples = clip(seconds: 600, gaps: gaps)
        let windows = plan(samples)

        #expect(windows.count == 8)
        #expect(windows.first?.range.lowerBound == 0)
        #expect(windows.last?.range.upperBound == samples.count)
        #expect(windows.allSatisfy { fits($0) && $0.range.count <= preferred && $0.voiced })
        for (previous, next) in zip(windows, windows.dropFirst()) {
            #expect(next.range.lowerBound > previous.range.lowerBound)
            #expect(previous.range.upperBound - next.range.lowerBound == rate)
            // Each cut lands in the middle of a pause.
            let cut = Double(previous.range.upperBound) / Double(rate)
            #expect(gaps.contains { cut > $0.0 && cut < $0.0 + $0.1 })
        }
        // The longest pause wins: the first cut is at 75.4 s, not 82.3 s.
        #expect(windows[0].range.upperBound == Int(75.4 * Double(rate)))
    }

    @Test func withoutAPauseTheQuietestFrameIsTheCut() {
        var samples = clip(seconds: 150)
        let quiet = Int(80.0 * Double(rate))
        for index in quiet..<quiet + 1_600 { samples[index] *= 0.5 }
        let windows = plan(samples)
        #expect(windows.count == 2)
        #expect(windows[0].range.upperBound == quiet + 800)
    }

    @Test func aSilentClipHasOnlyUnvoicedWindows() {
        let samples = [Float](repeating: 0.001, count: 400 * rate)
        let windows = plan(samples)
        #expect(windows.count == 5)
        #expect(windows.allSatisfy { !$0.voiced && $0.speechSeconds == 0 })
        #expect(windows.last?.range.upperBound == samples.count)
    }

    @Test func aWindowCountsItsSpeech() {
        // 40 s of tone with 10 s of silence from 10 s.
        let samples = clip(seconds: 40, gaps: [(10, 10)])
        let activity = VoiceActivity(samples: samples, sampleRate: rate)
        #expect(abs(activity.speechSeconds(in: 0..<samples.count) - 30) < 0.001)
        #expect(abs(activity.speechSeconds(in: 5 * rate..<25 * rate) - 10) < 0.001)
        #expect(activity.speechSeconds(in: 11 * rate..<19 * rate) == 0)
        // Part of a frame counts as that part.
        #expect(abs(activity.speechSeconds(in: 800..<1_600) - 0.05) < 0.0001)
    }

    @Test func aWindowSplitsAtTheQuietestPointOfItsMiddle() {
        // A pause at 40 s (in the middle half) and a longer one at 5 s (outside it).
        let samples = clip(seconds: 100, gaps: [(5, 3), (40, 0.6)])
        let activity = VoiceActivity(samples: samples, sampleRate: rate)
        let window = AudioWindow(range: 0..<samples.count, activity: activity)
        let halves = AudioWindowPlan.split(window, sampleRate: rate, activity: activity)
        #expect(halves?.count == 2)
        guard let halves, halves.count == 2 else { return }
        #expect(halves[0].range == 0..<Int(40.3 * Double(rate)))
        #expect(halves[1].range == Int(39.3 * Double(rate))..<samples.count)
        #expect(halves.allSatisfy { $0.voiced })
    }

    @Test func aSplitStaysWithinItsWindow() {
        let samples = clip(seconds: 300)
        let activity = VoiceActivity(samples: samples, sampleRate: rate)
        let window = AudioWindow(range: 100 * rate..<166 * rate, activity: activity)
        let halves = AudioWindowPlan.split(window, sampleRate: rate, activity: activity) ?? []
        #expect(halves.count == 2)
        #expect(halves.first?.range.lowerBound == window.range.lowerBound)
        #expect(halves.last?.range.upperBound == window.range.upperBound)
        #expect(halves.allSatisfy { $0.range.count >= 15 * rate && $0.range.count < window.range.count })
        if halves.count == 2 { #expect(halves[0].range.upperBound - halves[1].range.lowerBound == rate) }
    }

    @Test func aShortWindowDoesNotSplit() {
        let samples = clip(seconds: 60)
        let activity = VoiceActivity(samples: samples, sampleRate: rate)
        // Halves of 15 s need 30 s, less the 1 s both hear.
        #expect(AudioWindowPlan.split(AudioWindow(range: 0..<28 * rate, activity: activity), sampleRate: rate, activity: activity) == nil)
        #expect(AudioWindowPlan.split(AudioWindow(range: 0..<30 * rate, activity: activity), sampleRate: rate, activity: activity) != nil)
        #expect(AudioWindowPlan.split(AudioWindow(range: 0..<0, activity: activity), sampleRate: rate, activity: activity) == nil)
    }

    @Test func aSilentStretchOfALongClipIsUnvoiced() {
        let samples = clip(seconds: 400, gaps: [(150, 250)])
        let windows = plan(samples)
        #expect(windows.first?.voiced == true)
        #expect(windows.last?.voiced == false)
    }

    @Test func theOverlapCountsOnlyItsSpeech() {
        // Tone with a pause from 10 s to 12 s.
        let samples = clip(seconds: 30, gaps: [(10, 2)])
        let activity = VoiceActivity(samples: samples, sampleRate: rate)
        func window(_ from: Double, _ to: Double) -> AudioWindow {
            AudioWindow(range: Int(from * Double(rate))..<Int(to * Double(rate)), activity: activity)
        }
        // A cut in the pause: the second it shares is silent.
        #expect(AudioWindowPlan.overlapSpeechSeconds(window(0, 11.5), window(10.5, 30), activity: activity) == 0)
        // A cut in speech: all of it is speech.
        #expect(abs(AudioWindowPlan.overlapSpeechSeconds(window(0, 6), window(5, 30), activity: activity) - 1) < 0.001)
        // Half of it in the pause.
        #expect(abs(AudioWindowPlan.overlapSpeechSeconds(window(0, 10.5), window(9.5, 30), activity: activity) - 0.5) < 0.001)
        // Windows that don't meet share nothing.
        #expect(AudioWindowPlan.overlapSpeechSeconds(window(0, 5), window(6, 30), activity: activity) == 0)
    }

    @Test func tinyWindowsStillMoveForward() {
        let activity = VoiceActivity(energies: [], frameLength: 1_600)
        let windows = AudioWindowPlan.windows(sampleCount: 10_000, sampleRate: rate, activity: activity,
                                              contextTokens: 1, overlapSeconds: 5)
        #expect(windows.last?.range.upperBound == 10_000)
        #expect(zip(windows, windows.dropFirst()).allSatisfy { $1.range.lowerBound > $0.range.lowerBound })
    }
}

struct VoiceActivityTests {
    @Test func toneIsSpeechAndSilenceIsNot() {
        let tone = (0..<16_000).map { Float(0.2 * sin(Double($0) / 5)) }
        let samples = tone + [Float](repeating: 0, count: 16_000) + tone
        let activity = VoiceActivity(samples: samples, sampleRate: 16_000)
        #expect(activity.frameLength == 1_600)
        #expect(activity.voiced == Array(repeating: true, count: 10) + Array(repeating: false, count: 10) + Array(repeating: true, count: 10))
        #expect(activity.isVoiced(0..<100))
        #expect(!activity.isVoiced(16_000..<32_000))
        #expect(activity.isVoiced(31_999..<32_001))
    }

    @Test func theThresholdFollowsAQuietClip() {
        let quiet = (0..<16_000).map { Float(0.03 * sin(Double($0) / 5)) }
        let activity = VoiceActivity(samples: quiet + [Float](repeating: 0.001, count: 16_000), sampleRate: 16_000)
        #expect(activity.threshold < 0.02)
        #expect(activity.voiced.prefix(10).allSatisfy { $0 })
        #expect(activity.voiced.suffix(10).allSatisfy { !$0 })
    }

    @Test func roomNoiseIsSilence() {
        let activity = VoiceActivity(samples: [Float](repeating: 0.002, count: 32_000), sampleRate: 16_000)
        #expect(activity.threshold == VoiceActivity.floor)
        #expect(!activity.voiced.contains(true))
    }

    @Test func aShortLastFrameIsMeasured() {
        let activity = VoiceActivity(samples: [Float](repeating: 0.5, count: 1_700), sampleRate: 16_000)
        #expect(activity.energies.count == 2)
        #expect(activity.voiced == [true, true])
    }
}
