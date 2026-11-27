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
    /// Runs inside `start`, after the device opened, like time spent opening the device.
    var duringStart: (@MainActor () -> Void)?
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
        duringStart?()
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
    /// Runs a timer that is already due inside `schedule`, as the protocol allows for a zero delay.
    var firesDueTimersImmediately = false
    private var timers: [(due: TimeInterval, action: @Sendable @MainActor () -> Void)] = []

    var pendingTimers: Int { timers.count }

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) {
        if firesDueTimersImmediately, delay <= 0 { return action() }
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
    /// Request indexes whose handle was cancelled, in order.
    private(set) var cancelled: [Int] = []
    /// Answers inside `transcribe`, before the handle is returned.
    var immediateResult: Result<String, Error>?
    /// Answers from inside `cancel()`, like a transport reporting its own cancellation.
    var resultOnCancel: Result<String, Error>?
    /// Runs inside `transcribe`, before the handle is returned, like a reentrant UI or timer callback.
    var duringTranscribe: (@MainActor () -> Void)?
    private var completions: [@Sendable @MainActor (Result<String, Error>) -> Void] = []

    func transcribe(
        _ audio: CapturedAudio,
        completion: @escaping @Sendable @MainActor (Result<String, Error>) -> Void
    ) -> TranscriptionCancellation {
        let index = received.count
        received.append(audio)
        completions.append(completion)
        duringTranscribe?()
        if let immediateResult { completion(immediateResult) }
        return TranscriptionCancellation { [weak self] in
            guard let self else { return }
            self.cancelled.append(index)
            if let result = self.resultOnCancel { completion(result) }
        }
    }

    func complete(_ result: Result<String, Error>, request index: Int = 0) {
        guard completions.indices.contains(index) else { return XCTFail("no transcription request \(index)") }
        completions[index](result)
    }
}

/// Monotonic time under test control; advancing it delivers no timer.
@MainActor
final class TestClock {
    var now = ContinuousClock.now

    func advance(by seconds: Double) { now = now.advanced(by: .seconds(seconds)) }
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
