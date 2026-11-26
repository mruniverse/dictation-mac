import DictationCore
import Foundation
import XCTest

@MainActor
final class FakePermission: MicrophonePermission {
    private(set) var requests = 0
    private var pending: [@Sendable @MainActor (Bool) -> Void] = []

    func requestAccess(_ completion: @escaping @Sendable @MainActor (Bool) -> Void) {
        requests += 1
        pending.append(completion)
    }

    /// Answers every pending request, including those of sessions that already ended.
    func answer(_ granted: Bool) {
        let answers = pending
        pending = []
        answers.forEach { $0(granted) }
    }
}

@MainActor
final class FakeCapture: AudioCapture {
    private(set) var starts = 0
    private(set) var isRunning = false
    var startError: CaptureFailure?
    private var chunkSinks: [@Sendable @MainActor (AudioChunk) -> Void] = []
    private var onFailure: (@Sendable @MainActor (CaptureFailure) -> Void)?

    func start(
        onChunk: @escaping @Sendable @MainActor (AudioChunk) -> Void,
        onFailure: @escaping @Sendable @MainActor (CaptureFailure) -> Void
    ) throws {
        if let startError { throw startError }
        starts += 1
        isRunning = true
        chunkSinks.append(onChunk)
        self.onFailure = onFailure
    }

    func stop() { isRunning = false }

    /// Delivers through the callback of start `index` (default: latest), even after `stop()`,
    /// like a block still queued from the audio thread.
    func feed(_ chunks: [AudioChunk], start index: Int? = nil) {
        guard let sink = index.map({ chunkSinks[$0] }) ?? chunkSinks.last else { return }
        chunks.forEach { sink($0) }
    }

    func fail(_ failure: CaptureFailure) { onFailure?(failure) }
}

@MainActor
final class FakeScheduler: Scheduler {
    private(set) var now: TimeInterval = 0
    private var timers: [(due: TimeInterval, action: @Sendable @MainActor () -> Void)] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) {
        timers.append((now + delay, action))
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = timers.filter { $0.due <= now }.sorted { $0.due < $1.due }
        timers.removeAll { $0.due <= now }
        due.forEach { $0.action() }
    }
}

@MainActor
final class FakeTranscriber: Transcriber {
    private(set) var received: [CapturedAudio] = []
    private var completions: [@Sendable @MainActor (Result<String, Error>) -> Void] = []

    func transcribe(_ audio: CapturedAudio, completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void) {
        received.append(audio)
        completions.append(completion)
    }

    func complete(_ result: Result<String, Error>, request index: Int = 0) {
        guard completions.indices.contains(index) else { return XCTFail("no transcription request \(index)") }
        completions[index](result)
    }
}

struct SyntheticError: Error {}

/// Synthetic signal in 0.1 s blocks; never real speech.
enum Synthetic {
    static let rate = 48_000.0

    static func tone(seconds: Double, amplitude: Float = 0.1, rate: Double = rate) -> [AudioChunk] {
        blocks(seconds: seconds, rate: rate) { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
    }

    static func silence(seconds: Double) -> [AudioChunk] {
        blocks(seconds: seconds, rate: rate) { _ in 0 }
    }

    private static func blocks(seconds: Double, rate: Double, sample: (Int) -> Float) -> [AudioChunk] {
        let total = Int((seconds * rate).rounded())
        let size = Int(rate / 10)
        return stride(from: 0, to: total, by: size).map { first in
            AudioChunk(samples: (first..<min(first + size, total)).map(sample), sampleRate: rate)
        }
    }
}
